# UI Notes

- Funding votes now lock only the portion of tokens equivalent to the capped voting value. Display locked balances accordingly if shown.
- Voting power should display only unlocked tokens: subtract `lockedBalanceRequirement` from balances.
- Funding request voting power is time-weighted: start at 0.05% of holdings and scale to 0.5% after 12 months based on the weighted-average `balanceAge`; selling all tokens resets the age.
- Block self-voting in the UI for funding requests, CEO applications, and endorser selections.
- Expected voting rewards must be computed as 22% of the registered vote amount, not raw voting power, so capped proposals show accurate payouts.
