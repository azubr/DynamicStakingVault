## Usage guide

[check here](README.md)

## APY update notes

APY value is updated only on deposit/withdraw calls. APY is considered fixed between those calls, even if total assets cross n*1000 tokens threshold because of computed rewards. It is done this way because requrements state: 
> APY recalculates instantly upon each deposit or withdrawal event

If APY increase should happen between deposit/withdraw calls, it can be done with loop of
- computing next update timestamp
- updating totalAssets 
- updating APY

Gas use will increase, but this loop is only expected to execute 100 times for the vault lifetime. So additional gas will be distributed among different calls.

APY is converted to compound interest to per-second growth rate as $1 + rate = (1 + apy) ^ {1 ÷ yearSeconds} = 2 ^ {log_2(1 + apy) ÷ yearSeconds}$. This value is cached in a storage variable and resused until next APY update.
Then  updatedTotalAssets is computed as $totalAssets × (1 + rate) ^ {seconds}$.  TotalAssets is also saved to storage variable on every deposit/withdraw block.

Technically growth rate calculation uses 64.64-bit fixed point format and ABDKMath64x64 library. There is proof that  64.64-bit fixed point precision is sufficient for 200 years of 10..20% growth with sub-second error :
 - First second of 10.00% growth is $1.1^{1÷(365 days)} - 1 = 3.022e-9$ (fits to 40 bits in fraction part with 4 decimal valuable digits)
 - 200 years of 20% growth is $1.2^{200} = 7e+15$ (fits to 53 bits of integer part)

Final multiplication to totalAssets is done with full 256 bits precision.

## Withdrawal fees notes

Every deposit creates timelock for the deposited amount. Timelocks are identified by unique id. Timelocks are saved in linked lists per account. Timelocks are sorted by unlock date within each list in descending order. Token transfer also results in timelocks transfer. Sender's timelocks are merged with recepient's timelocks within transfer amount. Timelocks are released on withdraw, but never disposed. Disposal logic could be implemented later in order to receive gas refunds. 

Account timelocks can checked externally with ``lockedAmount()`` method. This method is also used in ``previewRedeem``/``previewWithdraw`` to deduct withdrawal fees from resulting amount.

## Security notes

``emergencyWithdraw()`` access is controlled by ``ADMIN_ROLE`` instead of ``EMERGENCY_ROLE`` because requirement states:
> Provide functions for emergency withdrawal of tokens by the **admin**
EmergencyWithdraw can be only done when emergncy wallet is set and the Vault is paused.

pause()/unpause() access is controlled by ``ADMIN_ROLE`` instead of ``EMERGENCY_ROLE`` because requirement states:
> Include an emergency stop mechanism (Pausable) which halts deposits and withdrawals when triggered by an **admin**

So ``EMERGENCY_ROLE`` only controls ``setEmergencyWallet()`` access.

Both roles are managed by themselves to prevent total control of a malicious admin. 

## Gas costs on deposit/withdraw flow

|                                  | deposit | maxWithdraw | previewWithdraw | withdraw |
|----------------------------------|---------|-------------|-----------------|----------|
| Default                          | 216462  | 18180       | 16257           | 89600    |
| 1 year + 1 day delay             | 234804  | 22033       | 20110           | 106474   |
| 101 years delay                  | 217704  | 22903       | 20980           | 110785   |
| No timelocks                     | 109873  | 11200       | 9268            | 77559    |
| No timelocks and 101 years delay | 128215  | 18212       | 16280           | 104816   |

### Cases explanation 
- *Default*: deposit and immediate withdraw. 1 timelock is created and checked, APY is updated 1 time
- *1 year + 1 day delay*: 1 year delay before deposit, then 1 day delay before withdrawal.  1 timelock is created and checked, APY is updated 2 times
- *101 years delay*: 1 year delay before deposit, then 100 year delay before withdrawal. 1 timelock is created, then expired. So timelock check is simplier. APY is updated 2 times.
- *No timelocks*: Timelocks-related code is commented. Deposit and immediate withdraw.  No timelocks created or checked, APY is updated 2 times
- *No timelocks and 101 years delay*: "No timelocks" + "101 years delay"

### Conclusion 
Most gas is consumed on fees timelocks, especially on deposit. APY/growth calculation normally consumes less gas than its saving. ABDKMath64x64 uses some offchain-computed constants for ``exp_2``. Other offchain calculation could give very little help here if any.

