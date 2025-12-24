// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBNBYieldStrategy} from "../IBNBYieldStrategy.sol";

interface IAnkrBNBStakingPool {
    function stakeCerts() external payable;
    function exchangeRatio() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWBNB is IERC20 {
    function withdraw(uint256 amount) external;
}

interface IRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract AnkrBNBYieldStrategy is IBNBYieldStrategy {
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_VALUATION_HAIRCUT_BPS = 500;
    uint256 private constant ONE = 1e18;

    address public immutable vault;
    address public immutable guardian;
    IAnkrBNBStakingPool public immutable stakingPool;
    IERC20 public immutable ankrBNB;
    IRouter public immutable router;
    IWBNB public immutable wbnb;

    uint16 public maxSlippageBps;
    uint16 public valuationHaircutBps;
    bool public paused;
    address public recoveryAddress;

    event MaxSlippageBpsSet(uint256 oldBps, uint256 newBps);
    event ValuationHaircutBpsSet(uint256 oldBps, uint256 newBps);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Recovered(address indexed token, uint256 amount, address indexed to);
    event RecoveryAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event WithdrawAllToVault(uint256 withdrawnBNB, uint256 lstSold);

    error NotVault();
    error NotGuardian();
    error PausedError();
    error NotPaused();
    error SlippageTooHigh();
    error ValuationHaircutTooHigh();
    error ZeroAmount();
    error BnbSendFail();
    error ApprovalFailed();
    error TransferFailed();
    error ZeroAddress();
    error InvalidRecoveryToken();
    error InvalidRecipient();

    modifier onlyVault() {
        if (msg.sender != vault) {
            revert NotVault();
        }
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) {
            revert NotGuardian();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PausedError();
        }
        _;
    }

    constructor(
        address vault_,
        address guardian_,
        address bnbStakingPool_,
        address ankrBNB_,
        address router_,
        address wbnb_,
        address recovery_
    ) {
        if (vault_ == address(0) || recovery_ == address(0)) {
            revert ZeroAddress();
        }
        guardian = guardian_;
        stakingPool = IAnkrBNBStakingPool(bnbStakingPool_);
        ankrBNB = IERC20(ankrBNB_);
        router = IRouter(router_);
        wbnb = IWBNB(wbnb_);
        vault = vault_;
        maxSlippageBps = 100;
        valuationHaircutBps = 100;
        recoveryAddress = recovery_;
    }

    receive() external payable {}

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setMaxSlippageBps(uint16 newBps) external onlyGuardian {
        if (newBps > MAX_SLIPPAGE_BPS) {
            revert SlippageTooHigh();
        }
        uint256 oldBps = maxSlippageBps;
        maxSlippageBps = newBps;
        emit MaxSlippageBpsSet(oldBps, newBps);
    }

    function setValuationHaircutBps(uint16 newBps) external onlyGuardian {
        if (newBps > MAX_VALUATION_HAIRCUT_BPS) {
            revert ValuationHaircutTooHigh();
        }
        uint256 oldBps = valuationHaircutBps;
        valuationHaircutBps = newBps;
        emit ValuationHaircutBpsSet(oldBps, newBps);
    }

    function setRecoveryAddress(address newRecovery) external onlyGuardian {
        if (newRecovery == address(0)) {
            revert ZeroAddress();
        }
        address oldRecovery = recoveryAddress;
        recoveryAddress = newRecovery;
        emit RecoveryAddressUpdated(oldRecovery, newRecovery);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyGuardian {
        if (!paused) {
            revert NotPaused();
        }
        if (token == address(0) || token == address(ankrBNB) || token == address(wbnb)) {
            revert InvalidRecoveryToken();
        }
        if (to != vault && to != recoveryAddress) {
            revert InvalidRecipient();
        }
        if (!IERC20(token).transfer(to, amount)) {
            revert TransferFailed();
        }
        emit Recovered(token, amount, to);
    }

    function deposit() external payable onlyVault whenNotPaused {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        stakingPool.stakeCerts{value: msg.value}();
    }

    function withdraw(uint256 bnbAmount) external onlyVault whenNotPaused returns (uint256 received) {
        if (bnbAmount == 0) {
            return 0;
        }

        uint256 ratio = _exchangeRatio();
        if (ratio == 0) {
            return 0;
        }

        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 ankrNeeded = _mulDivUp(bnbAmount, ONE, ratio);
        uint256 ankrToSwap = ankrNeeded > ankrBalance ? ankrBalance : ankrNeeded;
        if (ankrToSwap == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = address(ankrBNB);
        path[1] = address(wbnb);

        uint256 expectedBnb = (ankrToSwap * ratio) / ONE;
        uint256 amountOutMin = _minOutFromExpected(expectedBnb);

        _approve(ankrBNB, address(router), ankrToSwap);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(ankrToSwap, amountOutMin, path, address(this), block.timestamp);
        _approve(ankrBNB, address(router), 0);

        uint256 wbnbOut = amounts[amounts.length - 1];
        uint256 balanceBefore = address(this).balance;
        wbnb.withdraw(wbnbOut);
        uint256 bnbOut = address(this).balance - balanceBefore;
        if (bnbOut > 0) {
            (bool success,) = vault.call{value: bnbOut}("");
            if (!success) {
                revert BnbSendFail();
            }
        }
        return bnbOut;
    }

    function withdrawAllToVault() external onlyVault returns (uint256 received) {
        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 ratio = _exchangeRatio();
        if (ankrBalance > 0) {
            address[] memory path = new address[](2);
            path[0] = address(ankrBNB);
            path[1] = address(wbnb);

            uint256 expectedBnb = (ankrBalance * ratio) / ONE;
            uint256 amountOutMin = _minOutFromExpected(expectedBnb);
            _approve(ankrBNB, address(router), ankrBalance);
            uint256[] memory amounts =
                router.swapExactTokensForTokens(ankrBalance, amountOutMin, path, address(this), block.timestamp);
            _approve(ankrBNB, address(router), 0);

            uint256 wbnbOut = amounts[amounts.length - 1];
            uint256 balanceBefore = address(this).balance;
            wbnb.withdraw(wbnbOut);
            uint256 bnbOut = address(this).balance - balanceBefore;
            emit WithdrawAllToVault(bnbOut, ankrBalance);
        }

        uint256 totalBnb = address(this).balance;
        if (totalBnb > 0) {
            (bool success,) = vault.call{value: totalBnb}("");
            if (!success) {
                revert BnbSendFail();
            }
        }
        return totalBnb;
    }

    function totalAssets() external view returns (uint256) {
        uint256 ratio = _exchangeRatio();
        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 bnbValue = ratio == 0 ? 0 : (ankrBalance * ratio) / ONE;
        uint256 adjusted = (bnbValue * (BPS - valuationHaircutBps)) / BPS;
        return address(this).balance + adjusted;
    }

    function _exchangeRatio() internal view returns (uint256) {
        return stakingPool.exchangeRatio();
    }

    function _minOutFromExpected(uint256 expectedBnb) internal view returns (uint256) {
        if (expectedBnb == 0) {
            return 0;
        }
        uint256 afterHaircut = (expectedBnb * (BPS - valuationHaircutBps)) / BPS;
        return (afterHaircut * (BPS - maxSlippageBps)) / BPS;
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        uint256 product = a * b;
        return (product + denominator - 1) / denominator;
    }

    function _approve(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.approve.selector, spender, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert ApprovalFailed();
        }
    }
}
