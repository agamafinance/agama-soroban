#![no_std]
//! Oracle Adapter, the single source of truth for NAV.
//!
//! Bridges several feed types (Reflector price feeds, an off-chain private
//! credit reporter, Etherfuse bond pricing) behind one validated interface.

use soroban_sdk::{contract, contractimpl};

#[contract]
pub struct OracleAdapter;

#[contractimpl]
impl OracleAdapter {}
