// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LiquidityPool - AMM-пул ликвидности для DEX c постоянным произведением и TWAP-оракулом
/// @author ...
/// @notice Пул для обмена двух ERC20 токенов по модели x*y = k с выпуском LP токенов
/// @dev Использует OpenZeppelin ERC20, ReentrancyGuard, Ownable, Pausable.
///      Требует установки @openzeppelin/contracts в проекте.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Интерфейс для получения безопасного timestamp
interface IBlockTimestampProvider {
    function getBlockTimestamp() external view returns (uint256);
}

/// @notice Реализация провайдера timestamp по умолчанию
contract DefaultBlockTimestampProvider is IBlockTimestampProvider {
    /// @inheritdoc IBlockTimestampProvider
    function getBlockTimestamp() external view override returns (uint256) {
        return block.timestamp;
    }
}

/// @title LiquidityPool
/// @notice AMM-пул 2 токенов с LP токенами и комиссиями
/// @dev Хранит резервы, выпускает LP токены и предоставляет функции swap/add/remove liquidity.
///      Для продакшена рекомендуется вынести права владельца в timelock / DAO.
contract LiquidityPool is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Брошено, если указан не один из токенов пула
    error InvalidToken();
    /// @notice Брошено, если срок действия транзакции истёк
    error DeadlineExpired();
    /// @notice Брошено, если входные параметры невалидны
    error InvalidParameters();
    /// @notice Брошено, если недостаточно ликвидности или средств
    error InsufficientLiquidity();
    /// @notice Брошено, если расчёт вернул нулевой результат
    error InsufficientOutputAmount();
    /// @notice Брошено, если попытка указать слишком большую комиссию
    error FeeTooHigh();
    /// @notice Брошено, если адрес равен нулевому
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                             IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Первый токен пула
    /// @dev Неизменяемый после деплоя
    IERC20 public immutable token0;

    /// @notice Второй токен пула
    /// @dev Неизменяемый после деплоя
    IERC20 public immutable token1;

    /// @notice Провайдер блока timestamp (может быть изменён владельцем)
    IBlockTimestampProvider public timestampProvider;

    /*//////////////////////////////////////////////////////////////
                              POOL STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Резерв токена0 (скорректирован после последней операции)
    /// @dev Хранится отдельно от реального баланса контракта
    uint112 public reserve0;

    /// @notice Резерв токена1 (скорректирован после последней операции)
    uint112 public reserve1;

    /// @notice Последний timestamp, когда были обновлены резервы/оракул
    uint32 public blockTimestampLast;

    /// @notice Кумулятивная цена token0 в единицах token1 (для TWAP)
    uint256 public price0CumulativeLast;

    /// @notice Кумулятивная цена token1 в единицах token0 (для TWAP)
    uint256 public price1CumulativeLast;

    /*//////////////////////////////////////////////////////////////
                             FEE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Делитель для комиссий (в базисных пунктах, 1e4 = 100%)
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /// @notice Минимальное количество LP токенов, заблокированное навсегда (защита от манипуляций)
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @notice Адрес получателя заблокированного MINIMUM_LIQUIDITY
    /// @dev Нельзя использовать нулевой адрес, т.к. OpenZeppelin ERC20 запрещает mint на него
    address public constant MINIMUM_LIQUIDITY_RECIPIENT = address(0xdead);

    /// @notice Торговая комиссия пула в bps (например, 30 = 0.30%)
    uint256 public swapFeeBps;

    /// @notice Доля протокола от торговой комиссии в bps (из swapFeeBps)
    /// @dev Например: swapFeeBps = 30, protocolFeeShareBps = 5000 => 50% от комиссии идёт протоколу
    uint256 public protocolFeeShareBps;

    /// @notice Адрес получателя протокольных комиссий
    address public protocolFeeRecipient;

    /// @notice Максимально допустимая торговая комиссия (например 1% = 100 bps)
    uint256 public constant MAX_SWAP_FEE_BPS = 100;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Событие добавления ликвидности
    /// @param provider Адрес поставщика ликвидности
    /// @param amount0 Фактически внесённое количество token0
    /// @param amount1 Фактически внесённое количество token1
    /// @param liquidity Выпущенное количество LP токенов
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Событие удаления ликвидности
    /// @param provider Адрес получателя
    /// @param amount0 Количество возвращённого token0
    /// @param amount1 Количество возвращённого token1
    /// @param liquidity Сожжённое количество LP токенов
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Событие обмена
    /// @param sender Инициатор свопа
    /// @param tokenIn Адрес токена входа
    /// @param tokenOut Адрес токена выхода
    /// @param amountIn Количество входного токена
    /// @param amountOut Количество выходного токена
    /// @param to Адрес получателя выхода
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    );

    /// @notice Событие изменения комиссий
    /// @param swapFeeBps Новое значение торговой комиссии в bps
    /// @param protocolFeeShareBps Новое значение доли протокола в bps
    /// @param protocolFeeRecipient Новый адрес получателя комиссий
    event FeesUpdated(uint256 swapFeeBps, uint256 protocolFeeShareBps, address protocolFeeRecipient);

    /// @notice Событие изменения провайдера timestamp
    /// @param provider Новый провайдер
    event TimestampProviderUpdated(address provider);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Создаёт новый пул ликвидности двух токенов
    /// @param _token0 Адрес первого ERC20 токена
    /// @param _token1 Адрес второго ERC20 токена
    /// @param _swapFeeBps Торговая комиссия в bps (например, 30 = 0.30%)
    /// @param _protocolFeeShareBps Доля протокола в bps (0-10_000)
    /// @param _protocolFeeRecipient Получатель протокольных комиссий
    /// @param _owner Владелец пула (право менять комиссии и паузу)
    constructor(
        address _token0,
        address _token1,
        uint256 _swapFeeBps,
        uint256 _protocolFeeShareBps,
        address _protocolFeeRecipient,
        address _owner
    ) ERC20("DEX LP Token", "DLP") Ownable(_owner) {
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert InvalidParameters();
        if (_swapFeeBps > MAX_SWAP_FEE_BPS) revert FeeTooHigh();
        if (_protocolFeeShareBps > FEE_DENOMINATOR) revert InvalidParameters();
        if (_protocolFeeRecipient == address(0)) revert ZeroAddress();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);

        swapFeeBps = _swapFeeBps;
        protocolFeeShareBps = _protocolFeeShareBps;
        protocolFeeRecipient = _protocolFeeRecipient;

        timestampProvider = new DefaultBlockTimestampProvider();
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS & HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Проверка дедлайна, чтобы защититься от "старых" транзакций
    /// @param deadline Максимальный допустимый timestamp выполнения
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @notice Обновляет резервы и данные оракула на основе балансов контракта
    /// @param balance0 Фактический баланс token0 контракта
    /// @param balance1 Фактический баланс token1 контракта
    function _update(uint256 balance0, uint256 balance1) internal {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
            revert InvalidParameters();
        }

        uint32 timestamp = uint32(timestampProvider.getBlockTimestamp());
        uint32 timeElapsed = timestamp - blockTimestampLast;

        // Обновляем кумулятивные цены, если уже есть резервы и прошёл хотя бы 1 сек
        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            // цена token0 в token1 = reserve1 / reserve0
            price0CumulativeLast += uint256(uint224((uint256(reserve1) << 112) / reserve0)) * timeElapsed;

            // цена token1 в token0 = reserve0 / reserve1
            price1CumulativeLast += uint256(uint224((uint256(reserve0) << 112) / reserve1)) * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = timestamp;
    }

    /// @notice Возвращает текущие резервы и timestamp последнего обновления
    /// @return _reserve0 Резерв token0
    /// @return _reserve1 Резерв token1
    /// @return _timestampLast Последний timestamp обновления
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _timestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _timestampLast = blockTimestampLast;
    }

    /// @notice Внутренняя функция вычисления квадратного корня (Babylonian)
    /// @param y Входное значение
    /// @return z sqrt(y)
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y / 2 + 1;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Добавление ликвидности в пул
    /// @dev Минтит LP токены поверх модели Uniswap V2
    /// @param amount0Desired Желаемое количество token0
    /// @param amount1Desired Желаемое количество token1
    /// @param amount0Min Минимально допустимое количество token0 (slippage guard)
    /// @param amount1Min Минимально допустимое количество token1 (slippage guard)
    /// @param to Адрес получателя LP токенов
    /// @param deadline Дедлайн транзакции (unix timestamp)
    /// @return amount0 Фактически использованное количество token0
    /// @return amount1 Фактически использованное количество token1
    /// @return liquidity Количество выпущенных LP токенов
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount0Desired == 0 || amount1Desired == 0) revert InvalidParameters();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();

        if (_reserve0 == 0 && _reserve1 == 0) {
            // первая ликвидность устанавливает цену
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        } else {
            // поддерживаем существующий ценовой диапазон
            uint256 amount1Optimal = (amount0Desired * _reserve1) / _reserve0;
            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min) revert InsufficientLiquidity();
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
                if (amount0Optimal > amount0Desired || amount0Optimal < amount0Min) {
                    revert InsufficientLiquidity();
                }
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }
        }

        // трансфер токенов в пул
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // первая ликвидность: sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // Минтим MINIMUM_LIQUIDITY на технический burn-адрес вместо нулевого (см. OZ ERC20 v5)
            _mint(MINIMUM_LIQUIDITY_RECIPIENT, MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }

        if (liquidity == 0) revert InsufficientLiquidity();

        _mint(to, liquidity);
        _update(balance0, balance1);

        emit LiquidityAdded(to, amount0, amount1, liquidity);
    }

    /// @notice Удаление ликвидности из пула
    /// @param liquidity Количество LP токенов для сжигания
    /// @param amount0Min Минимальное количество token0 (slippage guard)
    /// @param amount1Min Минимальное количество token1 (slippage guard)
    /// @param to Адрес получателя токенов
    /// @param deadline Дедлайн транзакции
    /// @return amount0 Фактически полученное количество token0
    /// @return amount1 Фактически полученное количество token1
    function removeLiquidity(uint256 liquidity, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        if (to == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert InvalidParameters();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 _totalSupply = totalSupply();

        amount0 = (liquidity * _reserve0) / _totalSupply;
        amount1 = (liquidity * _reserve1) / _totalSupply;

        if (amount0 < amount0Min || amount1 < amount1Min) revert InsufficientLiquidity();

        _burn(msg.sender, liquidity);

        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        _update(balance0, balance1);

        emit LiquidityRemoved(to, amount0, amount1, liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Обмен "точное количество входа" на "минимум выхода"
    /// @dev Обмен возможен только между token0 и token1
    /// @param tokenIn Адрес входного токена (должен быть token0 или token1)
    /// @param amountIn Точное количество входного токена
    /// @param minAmountOut Минимально допустимое количество выходного токена
    /// @param to Адрес получателя выходного токена
    /// @param deadline Дедлайн транзакции
    /// @return amountOut Фактически полученное количество выходного токена
    function swapExactInput(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert InvalidParameters();

        bool zeroForOne;
        if (tokenIn == address(token0)) {
            zeroForOne = true;
        } else if (tokenIn == address(token1)) {
            zeroForOne = false;
        } else {
            revert InvalidToken();
        }

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (_reserve0 == 0 || _reserve1 == 0) revert InsufficientLiquidity();

        IERC20 inToken = zeroForOne ? token0 : token1;
        IERC20 outToken = zeroForOne ? token1 : token0;

        // трансфер входного токена в пул
        inToken.safeTransferFrom(msg.sender, address(this), amountIn);

        // пересчёт балансов
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        uint256 amountInEffective;
        uint256 reserveIn;
        uint256 reserveOut;

        if (zeroForOne) {
            amountInEffective = balance0 - _reserve0;
            reserveIn = _reserve0;
            reserveOut = _reserve1;
        } else {
            amountInEffective = balance1 - _reserve1;
            reserveIn = _reserve1;
            reserveOut = _reserve0;
        }

        // комиссия пула
        uint256 amountInWithFee = (amountInEffective * (FEE_DENOMINATOR - swapFeeBps)) / FEE_DENOMINATOR;

        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        // распределение протокольной комиссии
        if (swapFeeBps != 0 && protocolFeeShareBps != 0) {
            uint256 totalFee = (amountInEffective * swapFeeBps) / FEE_DENOMINATOR;
            uint256 protocolFee = (totalFee * protocolFeeShareBps) / FEE_DENOMINATOR;
            if (protocolFee > 0) {
                inToken.safeTransfer(protocolFeeRecipient, protocolFee);
            }
        }

        // отправка выходного токена
        outToken.safeTransfer(to, amountOut);

        // обновляем резервы и оракул
        balance0 = token0.balanceOf(address(this));
        balance1 = token1.balanceOf(address(this));
        _update(balance0, balance1);

        emit Swap(msg.sender, address(inToken), address(outToken), amountInEffective, amountOut, to);
    }

    /*//////////////////////////////////////////////////////////////
                                 ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Возвращает TWAP цены token0 в token1 за заданный период
    /// @dev Для простоты: вызывается off-chain дважды с разными timestamp и кумулятивной ценой
    /// @param price0CumulativeStart Кумулятивная цена token0 в token1 в начале периода
    /// @param timestampStart Timestamp начала периода
    /// @param price0CumulativeEnd Кумулятивная цена token0 в token1 в конце периода
    /// @param timestampEnd Timestamp конца периода
    /// @return price0AverageX112 Средняя цена token0 в token1 в формате UQ112x112
    function consultTWAP0(
        uint256 price0CumulativeStart,
        uint32 timestampStart,
        uint256 price0CumulativeEnd,
        uint32 timestampEnd
    ) external pure returns (uint224 price0AverageX112) {
        require(timestampEnd > timestampStart, "Invalid window");
        uint32 timeElapsed = timestampEnd - timestampStart;
        price0AverageX112 = uint224((price0CumulativeEnd - price0CumulativeStart) / timeElapsed);
    }

    /// @notice Возвращает TWAP цены token1 в token0 за заданный период
    /// @param price1CumulativeStart Кумулятивная цена token1 в token0 в начале периода
    /// @param timestampStart Timestamp начала периода
    /// @param price1CumulativeEnd Кумулятивная цена token1 в token0 в конце периода
    /// @param timestampEnd Timestamp конца периода
    /// @return price1AverageX112 Средняя цена token1 в token0 в формате UQ112x112
    function consultTWAP1(
        uint256 price1CumulativeStart,
        uint32 timestampStart,
        uint256 price1CumulativeEnd,
        uint32 timestampEnd
    ) external pure returns (uint224 price1AverageX112) {
        require(timestampEnd > timestampStart, "Invalid window");
        uint32 timeElapsed = timestampEnd - timestampStart;
        price1AverageX112 = uint224((price1CumulativeEnd - price1CumulativeStart) / timeElapsed);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Обновление параметров комиссий
    /// @param _swapFeeBps Новая торговая комиссия в bps
    /// @param _protocolFeeShareBps Новая доля протокола в bps (0-10_000)
    /// @param _protocolFeeRecipient Новый адрес получателя комиссий
    function setFees(uint256 _swapFeeBps, uint256 _protocolFeeShareBps, address _protocolFeeRecipient)
        external
        onlyOwner
    {
        if (_swapFeeBps > MAX_SWAP_FEE_BPS) revert FeeTooHigh();
        if (_protocolFeeShareBps > FEE_DENOMINATOR) revert InvalidParameters();
        if (_protocolFeeRecipient == address(0)) revert ZeroAddress();

        swapFeeBps = _swapFeeBps;
        protocolFeeShareBps = _protocolFeeShareBps;
        protocolFeeRecipient = _protocolFeeRecipient;

        emit FeesUpdated(_swapFeeBps, _protocolFeeShareBps, _protocolFeeRecipient);
    }

    /// @notice Установка кастомного провайдера timestamp (для L2/rollup и тестов)
    /// @param provider Адрес нового провайдера
    function setTimestampProvider(address provider) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        timestampProvider = IBlockTimestampProvider(provider);
        emit TimestampProviderUpdated(provider);
    }

    /// @notice Поставить пул на паузу (остановка swap/add/remove)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Снять пул с паузы
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Возвращает минимум из двух значений
    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
