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
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    uint256 private constant ONE = 1e18;

    address public immutable vault;
    address public immutable guardian;
    IAnkrBNBStakingPool public immutable stakingPool;
    IERC20 public immutable ankrBNB;
    IRouter public immutable router;
    IWBNB public immutable wbnb;

    uint256 public maxSlippageBps;
    bool public paused;

    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error NotVault();
    error NotGuardian();
    error PausedError();
    error SlippageTooHigh();
    error ZeroAmount();
    error BnbSendFail();
    error ApprovalFailed();
    error TransferFailed();
    error ZeroAddress();

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
        address wbnb_
    ) {
        if (vault_ == address(0)) {
            revert ZeroAddress();
        }
        guardian = guardian_;
        stakingPool = IAnkrBNBStakingPool(bnbStakingPool_);
        ankrBNB = IERC20(ankrBNB_);
        router = IRouter(router_);
        wbnb = IWBNB(wbnb_);
        vault = vault_;
        maxSlippageBps = 100;
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

    function setMaxSlippageBps(uint256 newBps) external onlyGuardian {
        if (newBps > MAX_SLIPPAGE_BPS) {
            revert SlippageTooHigh();
        }
        uint256 oldBps = maxSlippageBps;
        maxSlippageBps = newBps;
        emit SlippageUpdated(oldBps, newBps);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyGuardian {
        if (!IERC20(token).transfer(to, amount)) {
            revert TransferFailed();
        }
        emit EmergencyTokenRecovered(token, to, amount);
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
        uint256 ankrNeeded = _mulDivUp(bnbAmount, ratio, ONE);
        uint256 ankrToSwap = ankrNeeded > ankrBalance ? ankrBalance : ankrNeeded;
        if (ankrToSwap == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = address(ankrBNB);
        path[1] = address(wbnb);

        uint256[] memory quote = router.getAmountsOut(ankrToSwap, path);
        uint256 amountOutQuoted = quote[quote.length - 1];
        uint256 amountOutMin = (amountOutQuoted * (BPS - maxSlippageBps)) / BPS;

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

    function totalAssets() external view returns (uint256) {
        uint256 ratio = _exchangeRatio();
        uint256 ankrBalance = ankrBNB.balanceOf(address(this));
        uint256 bnbValue = ratio == 0 ? 0 : (ankrBalance * ONE) / ratio;
        return address(this).balance + bnbValue;
    }

    function _exchangeRatio() internal view returns (uint256) {
        return stakingPool.exchangeRatio();
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        uint256 product = a * b;
        return (product + denominator - 1) / denominator;
    }

    function _approve(IERC20 token, address spender, uint256 amount) internal {
        if (!token.approve(spender, amount)) {
            revert ApprovalFailed();
        }
    }
}
