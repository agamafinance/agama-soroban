#![no_std]
//! Vault contract, the USDC entry point of the protocol.
//!
//! Accepts deposits, mints agUSD 1:1, manages the two-step FIFO withdrawal
//! queue (`request_withdrawal` then `claim_withdrawal`), reads NAV from the
//! Oracle Adapter and routes capital through the Allocation Engine.

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct Vault;

#[contractimpl]
impl Vault {}
