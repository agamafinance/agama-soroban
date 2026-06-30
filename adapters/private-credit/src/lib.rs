// Private Credit Adapter — T2.1 (ETA: September 2026)
//
// Implements the uniform pool adapter interface for off-chain private credit
// originators. Tracks allocated capital and records repayments via deallocate().
// NAV is reported by the Oracle Adapter's custom reporter (7d staleness).
//
// Settlement timing: D+15 to D+90 depending on instrument type.
//
// Status: in development
