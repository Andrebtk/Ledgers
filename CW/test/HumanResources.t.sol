// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HumanResources.sol";
import "../src/IHumanResources.sol";

contract HumanResourcesTest is Test {
    HumanResources public hr;
    address public alice = makeAddr("alice");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpcUrl = vm.envString("OPTIMISM_RPC_URL");
        vm.createSelectFork(rpcUrl, 127000000);

        hr = new HumanResources();
        deal(hr.USDC(), address(hr), 100_000e6); // Fund HR with 100,000 USDC
    }

    function testRegisterAndSalaryAccrual() public {
        hr.registerEmployee(alice, 1000e18); // $1,000/week
        assertEq(hr.getActiveEmployeeCount(), 1);

        vm.warp(block.timestamp + 3.5 days);
        assertEq(hr.salaryAvailable(alice), 500e6);
    }

    function testUnauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(alice, 1000e18);
    }

    function testTerminateStopsAccrual() public {
        hr.registerEmployee(alice, 1000e18);
        vm.warp(block.timestamp + 1 weeks);

        hr.terminateEmployee(alice);
        assertEq(hr.getActiveEmployeeCount(), 0);

        vm.warp(block.timestamp + 2 weeks);
        assertEq(hr.salaryAvailable(alice), 1000e6);
    }

    function testWithdrawUsdc() public {
        hr.registerEmployee(alice, 1000e18);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);

        vm.prank(alice);
        hr.withdrawSalary();

        assertEq(IERC20(hr.USDC()).balanceOf(alice), 1000e6);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function testSwitchCurrencyAndWithdrawEth() public {
        hr.registerEmployee(alice, 1000e18);

        vm.prank(alice);
        hr.switchCurrency();

        vm.warp(vm.getBlockTimestamp() + 1 weeks);

        uint256 expectedEth = hr.salaryAvailable(alice);
        assertGt(expectedEth, 0);

        vm.prank(alice);
        hr.withdrawSalary();

        // Verify Alice received native ETH within 2% of Chainlink oracle price
        assertGe(alice.balance, (expectedEth * 98) / 100);
        assertEq(hr.salaryAvailable(alice), 0);
    }
}