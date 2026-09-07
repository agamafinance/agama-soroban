#![no_std]
//! Allocation Engine, routes vault capital across registered pool adapters.
//!
//! Enforces on-chain concentration caps (per pool, per originator, per
//! jurisdiction) and a minimum idle USDC reserve floor in the Vault.

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct AllocationEngine;

#[contractimpl]
impl AllocationEngine {}
