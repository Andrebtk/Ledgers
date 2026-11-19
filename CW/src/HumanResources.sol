// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./IHumanResources.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/ISwapRouter.sol";


// HR payroll: salaries accrue in USD, paid in USDC or ETH
contract HumanResources is IHumanResources {
    
    // Optimism addresses
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant ETH_USD_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address public constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint256 private _activeEmployeeCount;
    address private immutable _hrManager = msg.sender;

    struct Employee {
        uint256 weeklyUsdSalary;        // 18 decimals
        uint256 employedSince;
        uint256 terminatedAt;
        uint256 lastAccrualUpdate;      // start of the current accrual period
        uint256 accruedUsd;             // collected, unwithdrawn USD (18 decimals)
        bool prefersEth;                // false = USDC (default)
        bool exists;                    // was ever registered
    }


    mapping(address => Employee) private _employees;
    receive() external payable {}


    // HR Manager Functions

    function registerEmployee(address employee, uint256 weeklyUsdSalary) 
        external override {
            if(msg.sender != _hrManager) revert NotAuthorized();

            Employee storage emp = _employees[employee];

            if (emp.exists && emp.terminatedAt == 0) {
                revert EmployeeAlreadyRegistered();
            }


            // Re-registration keeps accruedUsd, restarts accrual, resets currency to USDC
            emp.weeklyUsdSalary = weeklyUsdSalary;
            emp.employedSince = block.timestamp;
            emp.terminatedAt = 0;
            emp.lastAccrualUpdate = block.timestamp;
            emp.prefersEth = false;
            emp.exists = true;

            _activeEmployeeCount++;
            emit EmployeeRegistered(employee, weeklyUsdSalary);
    }

    function terminateEmployee(address employee) external override {
        if(msg.sender != _hrManager) revert NotAuthorized();

        Employee storage emp = _employees[employee];
        if(!emp.exists || emp.terminatedAt != 0){
            revert EmployeeNotRegistered();
        }
        
        // Bank earned salary, then stop accrual
        emp.accruedUsd = _totalAccruedUsd(emp);
        emp.terminatedAt = block.timestamp;

        _activeEmployeeCount--;
        emit EmployeeTerminated(employee);
    }


    // Employee Functions

    function switchCurrency() external override {
        
        Employee storage emp = _employees[msg.sender];

        if (!emp.exists || emp.terminatedAt != 0) {
            revert NotAuthorized();
        }

        emp.prefersEth = !emp.prefersEth;
        emit CurrencySwitched(msg.sender, emp.prefersEth);
    }

    function withdrawSalary() external override {
        Employee storage emp = _employees[msg.sender];

        if (!emp.exists) {
            revert NotAuthorized();
        }

        uint256 totalUsd = _totalAccruedUsd(emp);
        
         // Reset balance before external calls (re-entrancy safe)
        emp.accruedUsd = 0;
        
        if(emp.terminatedAt == 0){ // not fired
            emp.lastAccrualUpdate = block.timestamp;
        }

        uint256 usdcAmount = totalUsd / 1e12; // 18 -> 6 decimals

        if(!emp.prefersEth){    
            emit SalaryWithdrawn(msg.sender, false, usdcAmount);

            if (usdcAmount > 0) {
                require(IERC20(USDC).transfer(msg.sender, usdcAmount), "USDC transfer failed");
            }
        }
        else {
            if (usdcAmount == 0) {
                emit SalaryWithdrawn(msg.sender, true, 0);
                return;
            }
            
            // Calculate expected ETH from Chainlink
            uint256 expectedEth = _usdToEth(totalUsd);
            uint256 minEthOut = (expectedEth * 98) / 100; // max 2% slippage vs oracle

            
            require(IERC20(USDC).approve(SWAP_ROUTER, usdcAmount), "USDC approve failed");
            
            uint256 ethAmount = _swapUsdcForWeth(usdcAmount, minEthOut);
            
            // Unwrap WETH to ETH and send
            IWETH(WETH).withdraw(ethAmount);
            emit SalaryWithdrawn(msg.sender, true, ethAmount);

            (bool ok, ) = msg.sender.call{value: ethAmount}("");
            require(ok, "ETH transfer failed");
        }

    }



    // Views

    function salaryAvailable(address employee) external view returns (uint256) {
        Employee storage emp = _employees[employee];

        if (!emp.exists) return 0;

        uint256 totalUsd = _totalAccruedUsd(emp);
        if(!emp.prefersEth) {
            return totalUsd / 1e12;
        }
        else {
            return _usdToEth(totalUsd);
        }
    }

    function hrManager() external view returns (address) {
        return _hrManager;
    } 

    function getActiveEmployeeCount() external view returns (uint256) {
        return _activeEmployeeCount;
    } 

    function getEmployeeInfo(address employee) external view returns (
        uint256 weeklyUsdSalary, uint256 employedSince, uint256 terminatedAt) { 
        
        
        Employee storage emp = _employees[employee];
        
        if (!emp.exists) {
            return (0,0,0);
        }

        return (emp.weeklyUsdSalary, emp.employedSince, emp.terminatedAt);
    }



    // Internal Helpers

    function _totalAccruedUsd(Employee storage emp) internal view returns (uint256) {
        if (!emp.exists) return 0;

        if (emp.terminatedAt != 0) {
            return emp.accruedUsd;
        }

        // Linear accrual since lastAccrualUpdate
        uint256 elapsed = block.timestamp - emp.lastAccrualUpdate;
        uint256 currentPeriodAccrued = (emp.weeklyUsdSalary * elapsed) / 1 weeks;
        return emp.accruedUsd + currentPeriodAccrued;
    } 


    function _usdToEth(uint256 usdAmount18) internal view returns (uint256) {
        if (usdAmount18 == 0) return 0;
        (, int256 price, , , ) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        require(price > 0, "Invalid oracle price");

        // usdAmount18 has 18 decimals; Chainlink ETH/USD price has 8 decimals -> result has 18 decimals
        return (usdAmount18 * 1e8) / uint256(price);
    }

    // Try the 0.05% pool, then the 0.3% pool; each must return >= minEthOut (2% max slippage vs oracle)
    function _swapUsdcForWeth(uint256 usdcAmount, uint256 minEthOut) internal returns (uint256) {
        uint24[3] memory fees = [uint24(3000), uint24(500), uint24(10000)];
        for (uint256 i = 0; i < fees.length; i++) {
            try ISwapRouter(SWAP_ROUTER).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: fees[i],
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcAmount,
                    amountOutMinimum: minEthOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 amountOut) {
                return amountOut;
            } catch {}
        }
        revert("Slippage too high");
    }


}