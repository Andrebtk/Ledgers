# HumanResources

**Author:** Andre Bertok

**Module:** Principles of Distributed Ledgers (70017): Coursework

An HR payroll contract on Optimism. Employees accrue a weekly USD salary continuously and withdraw it in USDC (default) or native ETH. Internal accounting is in USD with 18 decimals.

## Interface functions

| Function | Implementation |
|---|---|
| `registerEmployee` | `hrManager` only, otherwise `NotAuthorized`. Reverts with `EmployeeAlreadyRegistered` if the employee is active. Starts accrual and resets the currency to USDC. On re-registration, unwithdrawn salary is kept. Emits `EmployeeRegistered`. |
| `terminateEmployee` | `hrManager` only, otherwise `NotAuthorized`. Reverts with `EmployeeNotRegistered` if the employee is not active. Banks the earned salary and stops accrual. Emits `EmployeeTerminated`. |
| `withdrawSalary` | Active or terminated employees, otherwise `NotAuthorized`. Clears the balance before any external call (re-entrancy safe), then pays in USDC or ETH. Emits `SalaryWithdrawn`. |
| `switchCurrency` | Active employees only, otherwise `NotAuthorized`. Toggles USDC/ETH without withdrawing. Emits `CurrencySwitched`. |
| `salaryAvailable` | Accrued salary (`weeklyUsdSalary * elapsed / 1 week`, frozen on termination) in the preferred currency: USDC with 6 decimals, or ETH with 18 decimals at the live oracle price. 0 if never registered. |
| `hrManager` | The deployer, set immutably at deployment. |
| `getActiveEmployeeCount` | Number of active employees. |
| `getEmployeeInfo` | `(weeklyUsdSalary, employedSince, terminatedAt)`, where `terminatedAt` is 0 while active. All zeros if unknown. |


## Oracle and AMM integration

For ETH withdrawals, the contract reads the ETH/USD price from Chainlink and converts the owed USD into the expected ETH amount. It then swaps USDC for WETH on Uniswap V3 (trying the 0.3%, 0.05% and 1% pools in turn), with `amountOutMinimum` set to 98% of that amount, so the swap reverts if slippage or price manipulation exceeds 2%. The WETH is unwrapped and sent to the employee as native ETH with a checked `call`, after the balance has already been cleared to prevent re-entrancy.