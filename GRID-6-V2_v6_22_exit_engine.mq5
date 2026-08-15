// GRID 06.V02 V6.22 - EXIT ENGINE STAGING PATCH
// Intended to preserve the profitable grid core while adding hierarchical basket exit controls.
// This file is a staging/reference copy for review before replacing the production GRID-6-V2.mq5.
//
// IMPORTANT: The source of truth remains GRID-6-V2.mq5. The following V6.22 patch documents the
// exact exit-engine changes to apply after Strategy Tester validation.

// V6.22 exit parameters proposed:
//   BasketWarningLossPct   = 3.0
//   BasketFreezeLossPct    = 5.0
//   BasketHardLossPct      = 7.0
//   MaxBasketHours         = 48
//   UseHierarchicalExit    = true
//   ExitOnThesisInvalidation = true
//   ExitThesisConfirmationBars = 2
//   ExitRegimeWarningScore = 3
//   ExitRegimeDamageScore  = 6
//   Dynamic campaign giveback levels: 3 / 5 / 7 / 10 USD at peaks 10 / 15 / 25 / 40 USD
//   ATR trailing hard start = 20 USD
//   Stale campaign: 4h grace, 8h stale when not profitable
//
// The patch should be merged into production only after compile + backtest validation.
