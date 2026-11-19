// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HumanResources.sol";
import "../src/IHumanResources.sol";

/// @dev Employee contract that tries to re-enter withdrawSalary when it receives ETH.
contract ReentrantEmployee {
    HumanResources public immutable hr;
    uint256 public reentryCount;

    constructor(HumanResources _hr) {
        hr = _hr;
    }

    function switchCurrency() external {
        hr.switchCurrency();
    }

    function withdraw() external {
        hr.withdrawSalary();
    }

    receive() external payable {
        if (reentryCount == 0) {
            reentryCount++;
            hr.withdrawSalary();
        }
    }
}

/// @dev Employee contract that cannot receive ETH.
contract EthRejectingEmployee {
    HumanResources public immutable hr;

    constructor(HumanResources _hr) {
        hr = _hr;
    }

    function switchCurrency() external {
        hr.switchCurrency();
    }

    function withdraw() external {
        hr.withdrawSalary();
    }
}





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
        skip(1 weeks);

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



     // Mirror events from the interface so we can use vm.expectEmit
    event EmployeeRegistered(address indexed employee, uint256 weeklyUsdSalary);
    event EmployeeTerminated(address indexed employee);
    event SalaryWithdrawn(address indexed employee, bool isEth, uint256 amount);
    event CurrencySwitched(address indexed employee, bool isEth);

    uint256 constant WEEKLY = 1_000e18; // $1,000 per week
    uint256 constant FUNDING = 100_000e6; // matches deal() in setUp

    address public bob = makeAddr("bob");

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function manager() internal view returns (address) {
        return address(this); // test contract deploys hr in setUp, so it is the HR manager
    }

    function usdc() internal view returns (IERC20) {
        return IERC20(hr.USDC());
    }

    function feed() internal view returns (AggregatorV3Interface) {
        return AggregatorV3Interface(hr.ETH_USD_FEED());
    }

    function _register(address who, uint256 weekly) internal {
        vm.prank(manager());
        hr.registerEmployee(who, weekly);
    }

    function _terminate(address who) internal {
        vm.prank(manager());
        hr.terminateEmployee(who);
    }

    function _switch(address who) internal {
        vm.prank(who);
        hr.switchCurrency();
    }

    function _withdraw(address who) internal {
        vm.prank(who);
        hr.withdrawSalary();
    }

    function _oraclePrice() internal view returns (uint256) {
        (, int256 price,,,) = feed().latestRoundData();
        return uint256(price);
    }

    function _usdToEth(uint256 usd18) internal view returns (uint256) {
        return (usd18 * 1e8) / _oraclePrice();
    }

    /// @dev Returns (isEth, amount) of the last SalaryWithdrawn event in recorded logs.
    function _lastSalaryWithdrawn(address employee) internal view returns (bool found, bool isEth, uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SalaryWithdrawn(address,bool,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == address(hr) && l.topics[0] == sig && l.topics[1] == bytes32(uint256(uint160(employee)))) {
                (isEth, amount) = abi.decode(l.data, (bool, uint256));
                return (true, isEth, amount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOYMENT / VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_HrManagerIsDeployer() public view {
        assertEq(hr.hrManager(), manager());
    }

    function test_InitialState() public view {
        assertEq(hr.getActiveEmployeeCount(), 0);
        assertEq(usdc().balanceOf(address(hr)), FUNDING);
    }

    function test_GetEmployeeInfo_UnknownReturnsZeros() public view {
        (uint256 w, uint256 since, uint256 term) = hr.getEmployeeInfo(stranger);
        assertEq(w, 0);
        assertEq(since, 0);
        assertEq(term, 0);
    }

    function test_SalaryAvailable_UnknownReturnsZero() public view {
        assertEq(hr.salaryAvailable(stranger), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            REGISTER EMPLOYEE
    //////////////////////////////////////////////////////////////*/

    function test_Register_SetsInfoAndCount() public {
        _register(alice, WEEKLY);

        (uint256 w, uint256 since, uint256 term) = hr.getEmployeeInfo(alice);
        assertEq(w, WEEKLY);
        assertEq(since, block.timestamp);
        assertEq(term, 0);
        assertEq(hr.getActiveEmployeeCount(), 1);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Register_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(hr));
        emit EmployeeRegistered(alice, WEEKLY);
        _register(alice, WEEKLY);
    }

    function test_Register_MultipleEmployees() public {
        _register(alice, WEEKLY);
        _register(bob, 2 * WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);

        (uint256 w,,) = hr.getEmployeeInfo(bob);
        assertEq(w, 2 * WEEKLY);
    }

    function test_Register_RevertsIfNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(alice, WEEKLY);
    }

    function test_Register_RevertsIfEmployeeRegistersThemselves() public {
        _register(alice, WEEKLY);
        vm.prank(alice);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(bob, WEEKLY);
    }

    function test_Register_RevertsIfAlreadyActive() public {
        _register(alice, WEEKLY);
        vm.prank(manager());
        vm.expectRevert(IHumanResources.EmployeeAlreadyRegistered.selector);
        hr.registerEmployee(alice, 2 * WEEKLY);
    }

    /// forge-config: default.fuzz.runs = 10
    function testFuzz_Register_RevertsForAnyNonManager(address caller) public {
        vm.assume(caller != manager());
        vm.prank(caller);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(alice, WEEKLY);
    }

    /*//////////////////////////////////////////////////////////////
                           TERMINATE EMPLOYEE
    //////////////////////////////////////////////////////////////*/

    function test_Terminate_UpdatesInfoAndCount() public {
        _register(alice, WEEKLY);
        uint256 since = vm.getBlockTimestamp();
        skip(1 weeks);
        _terminate(alice);

        (uint256 w, uint256 s, uint256 term) = hr.getEmployeeInfo(alice);
        assertEq(w, WEEKLY);
        assertEq(s, since);
        assertEq(term, block.timestamp);
        assertEq(hr.getActiveEmployeeCount(), 0);
    }

    function test_Terminate_EmitsEvent() public {
        _register(alice, WEEKLY);
        vm.expectEmit(true, false, false, true, address(hr));
        emit EmployeeTerminated(alice);
        _terminate(alice);
    }

    function test_Terminate_RevertsIfNotManager() public {
        _register(alice, WEEKLY);
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.terminateEmployee(alice);
    }

    function test_Terminate_RevertsIfNeverRegistered() public {
        vm.prank(manager());
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        hr.terminateEmployee(stranger);
    }

    function test_Terminate_RevertsIfAlreadyTerminated() public {
        _register(alice, WEEKLY);
        _terminate(alice);
        vm.prank(manager());
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        hr.terminateEmployee(alice);
    }

    function test_Terminate_StopsAccrual() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _terminate(alice);
        assertEq(hr.salaryAvailable(alice), 1_000e6);

        skip(10 weeks);
        assertEq(hr.salaryAvailable(alice), 1_000e6);
    }

    function test_Terminate_OnlyAffectsTargetEmployee() public {
        _register(alice, WEEKLY);
        _register(bob, WEEKLY);
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);

        assertEq(hr.salaryAvailable(alice), 1_000e6);
        assertEq(hr.salaryAvailable(bob), 2_000e6);
        assertEq(hr.getActiveEmployeeCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             RE-REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_ReRegister_AfterTermination() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);

        _register(alice, 2 * WEEKLY);
        (uint256 w, uint256 since, uint256 term) = hr.getEmployeeInfo(alice);
        assertEq(w, 2 * WEEKLY);
        assertEq(since, block.timestamp);
        assertEq(term, 0);
        assertEq(hr.getActiveEmployeeCount(), 1);
    }

    function test_ReRegister_KeepsUnwithdrawnSalaryAndRestartsAccrual() public {
        _register(alice, WEEKLY);
        skip(1 weeks); // earns $1,000
        _terminate(alice);
        skip(5 weeks); // nothing earned while terminated

        _register(alice, 2 * WEEKLY);
        assertEq(hr.salaryAvailable(alice), 1_000e6);

        skip(1 weeks); // earns $2,000 at new rate
        assertEq(hr.salaryAvailable(alice), 3_000e6);

        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 3_000e6);
    }

    function test_ReRegister_ResetsCurrencyToUsdc() public {
        _register(alice, WEEKLY);
        _switch(alice); // ETH
        skip(1 weeks);
        _terminate(alice);
        _register(alice, WEEKLY);

        // Back in USDC mode: available salary is USDC-scaled
        assertEq(hr.salaryAvailable(alice), 1_000e6);

        // Next switch should go to ETH (proving the reset went to USDC)
        vm.expectEmit(true, false, false, true, address(hr));
        emit CurrencySwitched(alice, true);
        _switch(alice);
    }

    /*//////////////////////////////////////////////////////////////
                             SALARY ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function test_Accrual_PartialWeek() public {
        _register(alice, WEEKLY);
        skip(3.5 days);
        assertEq(hr.salaryAvailable(alice), 500e6);
    }

    function test_Accrual_MultipleWeeks() public {
        _register(alice, WEEKLY);
        skip(2 weeks + 1 days);
        // 2 weeks + 1/7 week => 2000 + 142.857142...
        assertEq(hr.salaryAvailable(alice), (WEEKLY * (2 weeks + 1 days)) / 1 weeks / 1e12);
    }

    function test_Accrual_PerSecond() public {
        _register(alice, 604_800e18); // $1 per second
        skip(1);
        assertEq(hr.salaryAvailable(alice), 1e6);
    }

    function testFuzz_Accrual_Linear(uint256 weekly, uint256 elapsed) public {
        weekly = bound(weekly, 1e18, 1_000_000e18);
        elapsed = bound(elapsed, 0, 520 weeks);

        _register(alice, weekly);
        skip(elapsed);
        assertEq(hr.salaryAvailable(alice), (weekly * elapsed) / 1 weeks / 1e12);
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW SALARY: USDC
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUsdc_TransfersAndResets() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _withdraw(alice);

        assertEq(usdc().balanceOf(alice), 1_000e6);
        assertEq(usdc().balanceOf(address(hr)), FUNDING - 1_000e6);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_WithdrawUsdc_EmitsEvent() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        vm.expectEmit(true, false, false, true, address(hr));
        emit SalaryWithdrawn(alice, false, 1_000e6);
        _withdraw(alice);
    }

    function test_WithdrawUsdc_AccrualContinuesAfterWithdraw() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _withdraw(alice);
        skip(3.5 days);
        assertEq(hr.salaryAvailable(alice), 500e6);
        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 1_500e6);
    }

    function test_WithdrawUsdc_ZeroAvailableDoesNotTransfer() public {
        _register(alice, WEEKLY);
        _withdraw(alice); // same block, nothing accrued
        assertEq(usdc().balanceOf(alice), 0);
        assertEq(usdc().balanceOf(address(hr)), FUNDING);
    }

    function test_WithdrawUsdc_TerminatedEmployeeCanWithdraw() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);

        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 1_000e6);
        assertEq(hr.salaryAvailable(alice), 0);

        // Cannot withdraw twice
        skip(1 weeks);
        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 1_000e6);
    }

    function test_WithdrawUsdc_RevertsWhenContractUnderfunded() public {
        deal(address(usdc()), address(hr), 0);
        _register(alice, WEEKLY);
        skip(1 weeks);

        vm.prank(alice);
        vm.expectRevert();
        hr.withdrawSalary();

        // Salary is not lost because the whole tx reverted
        assertEq(hr.salaryAvailable(alice), 1_000e6);
    }

    function test_Withdraw_RevertsIfNeverRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    function test_Withdraw_RevertsForManager() public {
        vm.prank(manager());
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW SALARY: ETH
    //////////////////////////////////////////////////////////////*/

    function test_SalaryAvailable_EthMatchesOracle() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        uint256 expected = _usdToEth(WEEKLY);
        assertEq(hr.salaryAvailable(alice), expected);
        assertGt(expected, 0);
    }

    function test_WithdrawEth_SendsNativeEthWithinSlippage() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        uint256 expectedEth = hr.salaryAvailable(alice);
        uint256 balBefore = alice.balance;
        uint256 usdcBefore = usdc().balanceOf(address(hr));

        _withdraw(alice);

        uint256 received = alice.balance - balBefore;
        assertGe(received, (expectedEth * 98) / 100);
        assertEq(hr.salaryAvailable(alice), 0);
        assertEq(usdc().balanceOf(address(hr)), usdcBefore - 1_000e6);
        assertEq(usdc().balanceOf(alice), 0);
    }

    function test_WithdrawEth_NoWethOrEthLeftInContract() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);
        _withdraw(alice);

        assertEq(IERC20(hr.WETH()).balanceOf(address(alice)), 0);
        assertEq(IERC20(hr.WETH()).balanceOf(address(hr)), 0);
        assertEq(address(hr).balance, 0);
    }

    function test_WithdrawEth_EmitsEventWithEthAmount() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        uint256 balBefore = alice.balance;
        vm.recordLogs();
        _withdraw(alice);

        (bool found, bool isEth, uint256 amount) = _lastSalaryWithdrawn(alice);
        assertTrue(found);
        assertTrue(isEth);
        assertEq(amount, alice.balance - balBefore);
    }

    function test_WithdrawEth_ZeroAvailableDoesNotSwap() public {
        _register(alice, WEEKLY);
        _switch(alice);
        _withdraw(alice); // same block
        assertEq(alice.balance, 0);
        assertEq(usdc().balanceOf(address(hr)), FUNDING);
    }

    function test_WithdrawEth_TerminatedEmployeeCanWithdraw() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);

        uint256 expected = hr.salaryAvailable(alice);
        _withdraw(alice);
        assertGe(alice.balance, (expected * 98) / 100);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_WithdrawEth_RevertsOnExcessiveSlippage() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        // Make the oracle report ETH 10% cheaper than reality, so the contract
        // expects ~11% more ETH than the AMM can give -> swap must revert.
        uint256 realPrice = _oraclePrice();
        vm.mockCall(
            address(feed()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256((realPrice * 90) / 100), block.timestamp, block.timestamp, uint80(1))
        );

        vm.prank(alice);
        vm.expectRevert();
        hr.withdrawSalary();

        vm.clearMockedCalls();
        // Salary still intact
        assertEq(hr.salaryAvailable(alice), _usdToEth(WEEKLY));
    }

    function test_WithdrawEth_SucceedsWithinSlippageTolerance() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        // Oracle reports ETH 1% more expensive -> expects less ETH -> swap passes.
        uint256 realPrice = _oraclePrice();
        vm.mockCall(
            address(feed()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256((realPrice * 101) / 100), block.timestamp, block.timestamp, uint80(1))
        );

        _withdraw(alice);
        assertGt(alice.balance, 0);
    }

    function test_WithdrawEth_RevertsOnInvalidOraclePrice() public {
        _register(alice, WEEKLY);
        _switch(alice);
        skip(1 weeks);

        vm.mockCall(
            address(feed()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        vm.prank(alice);
        vm.expectRevert();
        hr.withdrawSalary();
    }

    function test_WithdrawEth_ReentrancySafe() public {
        ReentrantEmployee attacker = new ReentrantEmployee(hr);
        _register(address(attacker), WEEKLY);
        attacker.switchCurrency();
        skip(1 weeks);

        uint256 expected = hr.salaryAvailable(address(attacker));
        uint256 usdcBefore = usdc().balanceOf(address(hr));

        attacker.withdraw();

        assertEq(attacker.reentryCount(), 1);
        // Only one week of salary was paid out despite the re-entrant call
        assertEq(usdc().balanceOf(address(hr)), usdcBefore - 1_000e6);
        assertGe(address(attacker).balance, (expected * 98) / 100);
        assertLe(address(attacker).balance, (expected * 102) / 100);
        assertEq(hr.salaryAvailable(address(attacker)), 0);
    }

    function test_WithdrawEth_RevertsIfRecipientRejectsEth() public {
        EthRejectingEmployee emp = new EthRejectingEmployee(hr);
        _register(address(emp), WEEKLY);
        emp.switchCurrency();
        skip(1 weeks);

        vm.expectRevert();
        emp.withdraw();

        // Salary not lost
        assertEq(hr.salaryAvailable(address(emp)), _usdToEth(WEEKLY));
    }

    /*//////////////////////////////////////////////////////////////
                            SWITCH CURRENCY
    //////////////////////////////////////////////////////////////*/

    function test_Switch_TogglesAndEmits() public {
        _register(alice, WEEKLY);

        vm.expectEmit(true, false, false, true, address(hr));
        emit CurrencySwitched(alice, true);
        _switch(alice);

        vm.expectEmit(true, false, false, true, address(hr));
        emit CurrencySwitched(alice, false);
        _switch(alice);
    }

    function test_Switch_DoesNotTriggerWithdrawal() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _switch(alice);

        assertEq(usdc().balanceOf(alice), 0);
        assertEq(alice.balance, 0);
        assertEq(hr.salaryAvailable(alice), _usdToEth(WEEKLY));
    }

    function test_Switch_AccruedSalaryPaidInNewCurrency() public {
        _register(alice, WEEKLY);
        skip(1 weeks); // accrued while in USDC mode
        _switch(alice); // now ETH

        uint256 expected = hr.salaryAvailable(alice);
        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 0);
        assertGe(alice.balance, (expected * 98) / 100);
    }

    function test_Switch_BackToUsdc() public {
        _register(alice, WEEKLY);
        _switch(alice);
        _switch(alice);
        skip(1 weeks);
        assertEq(hr.salaryAvailable(alice), 1_000e6);
        _withdraw(alice);
        assertEq(usdc().balanceOf(alice), 1_000e6);
    }

    function test_Switch_RevertsIfNeverRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    function test_Switch_RevertsIfTerminated() public {
        _register(alice, WEEKLY);
        _terminate(alice);
        vm.prank(alice);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    function test_Switch_RevertsForManager() public {
        vm.prank(manager());
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    /*//////////////////////////////////////////////////////////////
                          ACTIVE EMPLOYEE COUNT
    //////////////////////////////////////////////////////////////*/

    function test_ActiveCount_TracksLifecycle() public {
        _register(alice, WEEKLY);
        _register(bob, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);

        _terminate(alice);
        assertEq(hr.getActiveEmployeeCount(), 1);

        _register(alice, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);

        _terminate(alice);
        _terminate(bob);
        assertEq(hr.getActiveEmployeeCount(), 0);
    }


}