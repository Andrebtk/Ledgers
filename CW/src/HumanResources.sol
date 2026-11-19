pragma solidity ^0.8.24;

import "./IHumanResources.sol";
import "./interfaces/IERC20.sol";

contract HumanResources is IHumanResources {
    uint256 private _activeEmployeeCount;
    address private immutable _hrManager = msg.sender;

    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    struct Employee {
        uint256 weeklyUsdSalary;
        uint256 employedSince;
        uint256 terminatedAt;
        uint256 lastAccrualUpdate;
        uint256 accruedUsd;
        bool prefersEth;
        bool exists;
    }

    mapping(address => Employee) private _employees;

    // HR Manager Functions

    function registerEmployee(address employee, uint256 weeklyUsdSalary) 
        external override {
            if(msg.sender != _hrManager) revert NotAuthorized();

            Employee storage emp = _employees[employee];

            if (emp.exists && emp.terminatedAt == 0) {
                revert EmployeeAlreadyRegistered();
            }

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
        emp.accruedUsd = 0;
        if(emp.terminatedAt == 0){ // not fired
            emp.lastAccrualUpdate = block.timestamp;
        }

        if(!emp.prefersEth){
            uint256 usdcAmount = totalUsd / 1e12;

            if (usdcAmount > 0) {
                require(IERC20(USDC).transfer(msg.sender, usdcAmount), "USDC transfer failed");
            }


            emit SalaryWithdrawn(msg.sender, false, usdcAmount);
        }
        else {
            // TO DO
            emit SalaryWithdrawn(msg.sender, false, 0);
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
            // TODO
            return 0;
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


        uint256 elapsed = block.timestamp - emp.lastAccrualUpdate;
        uint256 currentPeriodAccrued = (emp.weeklyUsdSalary * elapsed) / 1 weeks;
        return emp.accruedUsd + currentPeriodAccrued;
    } 


}