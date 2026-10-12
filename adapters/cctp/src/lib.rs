#![no_std]
//! Cross chain adapter: the pool whose capital leaves Stellar.
//!
//! Every other adapter in this repository holds its position on Stellar, so
//! `get_exposure` and the USDC on the contract's balance are two views of one
//! thing. This one is different in the only way that matters: `allocate` burns
//! the Vault's USDC through Circle's CCTP and it reappears on another chain,
//! minted to an address this contract cannot verify, read, or recall. From the
//! moment the burn mines, the exposure booked here is a claim on something no
//! Soroban call can see.
//!
//! That is not a flaw to engineer away. It is what the protocol does: deposits
//! land on Stellar and the credit book that earns on them is on an EVM chain,
//! so reserves have to leave before anything is earned. The adapter's job is to
//! make the leaving honest, which means three things.
//!
//! # The destination is config, not a parameter
//!
//! `allocate` takes an amount and nothing else. The destination domain and the
//! mint recipient are stored, admin gated, and refused while any exposure is
//! booked. An adapter that took the recipient per call would let whoever can
//! call allocate choose where the money goes, and the Engine's admin is not the
//! person that decision belongs to. CCTP carries 32 bare bytes with no type
//! tag and no checksum, so a wrong recipient is not rejected anywhere: it is
//! minted to an address nobody holds the key to, and there is no second
//! transaction that fixes it.
//!
//! # The fee means the book can never close by itself
//!
//! Circle takes a fee on the crossing and the decimals differ, 7 here and 6 on
//! every EVM chain. So the amount that arrives is smaller than the amount
//! burned, always, and the round trip back is smaller again. Exposure booked
//! here is therefore never fully recoverable by `deallocate`, not because
//! anything went wrong but because two crossings cost two fees.
//!
//! This makes `write_down` the ordinary path for this pool rather than the
//! distress path it is for a credit adapter. The alternative was to have
//! `deallocate` quietly tolerate a shortfall, which would mean the Engine's
//! book and the cash agreeing only because the adapter stopped checking. A fee
//! is a real loss of principal and it is recognised as one.
//!
//! # Nothing here can pull capital back
//!
//! There is no entry point that reaches across and retrieves funds, because
//! none can exist: the return crossing is initiated on the far chain and lands
//! on this contract's balance as an ordinary mint. `deallocate` then books it
//! home. So a return that has not arrived is not a failure this contract can
//! report, and the Engine admin must not deallocate against money that is not
//! here yet. `deallocate` enforces exactly that, by checking the balance before
//! it moves anything.
use soroban_sdk::{
    contract, contractclient, contractevent, contracterror, contractimpl, contracttype,
    symbol_short, token::TokenClient, Address, BytesN, Env, Symbol,
};

/// The subset of Circle's TokenMessengerMinter this adapter calls.
///
/// Declared here rather than imported because Circle ships no Soroban crate,
/// and a hand written client is the only place the argument order is pinned.
/// `deposit_for_burn` and not `deposit_for_burn_with_hook`: the hook exists so
/// a Stellar destination can forward after minting, and an EVM destination
/// mints straight to the recipient address with nothing to forward.
#[contractclient(name = "TokenMessengerClient")]
pub trait TokenMessenger {
    fn deposit_for_burn(
        e: Env,
        caller: Address,
        amount: i128,
        destination_domain: u32,
        mint_recipient: BytesN<32>,
        burn_token: Address,
        destination_caller: BytesN<32>,
        max_fee: i128,
        min_finality_threshold: u32,
    );
}

#[contractclient(name = "EngineClient")]
pub trait Engine {
    fn vault(e: Env) -> Address;
}

#[contractclient(name = "VaultClient")]
pub trait Vault {
    fn usdc(e: Env) -> Address;
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AdapterError {
    NotInitialized = 701,
    InvalidAmount = 702,
    /// Deallocating more than is currently deployed.
    ExposureUnderflow = 703,
    NotAdmin = 704,
    /// The Engine and Vault pointers cannot move while the adapter holds
    /// booked exposure or USDC.
    NotEmpty = 705,
    /// The proposed Engine does not answer that it governs the proposed Vault.
    CounterpartyMismatch = 706,
    WriteDownExceedsExposure = 707,
    NoPendingAdmin = 708,
    NotPendingAdmin = 709,
    NotAuthorized = 710,
    NothingToRecover = 711,
    /// A mint recipient of 32 zero bytes. CCTP would accept it and the money
    /// would be minted to the zero address on the far chain.
    InvalidMintRecipient = 712,
    /// The destination cannot be repointed while capital is in flight or
    /// deployed. Changing it then would send the next crossing somewhere the
    /// booked exposure was never owed to.
    DestinationLocked = 713,
    /// `deallocate` was asked for more USDC than has actually come back from
    /// the far chain and landed on this contract.
    ReturnNotArrived = 714,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Engine,
    Vault,
    Usdc,
    Exposure,
    PendingAdmin,
    /// Circle's TokenMessengerMinter on Stellar.
    Messenger,
    /// CCTP domain of the chain capital is sent to.
    Domain,
    /// The 32 bytes CCTP mints to on that chain. For an EVM destination this is
    /// the 20 byte address left padded, which is the whole of the encoding and
    /// the only part a mistake is invisible in.
    Recipient,
    /// Ceiling on Circle's fee, in basis points of the amount crossed.
    MaxFeeBps,
}

/// Emitted when capital is burned towards another chain. The amount and the
/// destination are both here because this is the last point at which either is
/// observable from Stellar: after this the position exists only on the far
/// chain and in this contract's exposure number.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Burned {
    #[topic]
    pub domain: u32,
    pub amount: i128,
    pub recipient: BytesN<32>,
    pub exposure: i128,
}

/// Emitted when capital that came back from the far chain is booked home.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Returned {
    #[topic]
    pub vault: Address,
    pub amount: i128,
    pub exposure: i128,
}

/// Emitted when the destination is set or changed. The one decision this
/// adapter makes that cannot be undone, so it belongs in the stream.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DestinationSet {
    #[topic]
    pub domain: u32,
    pub recipient: BytesN<32>,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WrittenDown {
    pub amount: i128,
    pub exposure: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SurplusRecovered {
    #[topic]
    pub vault: Address,
    pub amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CounterpartiesSet {
    #[topic]
    pub engine: Address,
    #[topic]
    pub vault: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminProposed {
    #[topic]
    pub new_admin: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminChanged {
    #[topic]
    pub admin: Address,
}

const DAY: u32 = 17280;

#[contract]
pub struct CctpAdapter;

#[contractimpl]
impl CctpAdapter {
    #[allow(clippy::too_many_arguments)]
    pub fn __constructor(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
        usdc: Address,
        messenger: Address,
        domain: u32,
        recipient: BytesN<32>,
        max_fee_bps: u32,
    ) -> Result<(), AdapterError> {
        admin.require_auth();
        Self::require_symmetry(&e, &engine, &vault, &usdc)?;
        Self::require_recipient(&recipient)?;
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Messenger, &messenger);
        e.storage().instance().set(&Cfg::Domain, &domain);
        e.storage().instance().set(&Cfg::Recipient, &recipient);
        e.storage().instance().set(&Cfg::MaxFeeBps, &max_fee_bps);
        e.storage().instance().set(&Cfg::Exposure, &0i128);
        Self::bump(&e);
        DestinationSet { domain, recipient }.publish(&e);
        Ok(())
    }

    /// Burn USDC towards the far chain and book the exposure.
    ///
    /// Called by the Engine after the Vault has released the USDC to this
    /// contract, which is the same handshake every other adapter uses. The
    /// difference is what happens next and it is not reversible, so there is
    /// deliberately no amount of configuration in this call: the destination
    /// was decided when it was set, under the admin, with no exposure booked.
    ///
    /// The allowance granted to the messenger is exactly the amount and expires
    /// on the next ledger. CCTP pulls through `transfer_from`, so some
    /// allowance has to exist; leaving a standing one would mean a contract
    /// that could be drained by a messenger upgrade nobody here controls.
    pub fn allocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let usdc: Address = Self::cfg(&e, &Cfg::Usdc)?;
        let messenger: Address = Self::cfg(&e, &Cfg::Messenger)?;
        let recipient: BytesN<32> = Self::cfg(&e, &Cfg::Recipient)?;
        let domain: u32 = e
            .storage()
            .instance()
            .get(&Cfg::Domain)
            .ok_or(AdapterError::NotInitialized)?;
        let max_fee_bps: u32 = e
            .storage()
            .instance()
            .get(&Cfg::MaxFeeBps)
            .ok_or(AdapterError::NotInitialized)?;

        let here = e.current_contract_address();
        let token = TokenClient::new(&e, &usdc);
        token.approve(&here, &messenger, &amount, &(e.ledger().sequence() + 1));

        // The fee ceiling is a share of the amount rather than a constant, so it
        // scales with the crossing instead of being generous for a small one and
        // binding for a large one. Circle refuses the burn if its own fee would
        // exceed this, which is the only protection against crossing at a price
        // nobody agreed to.
        let max_fee = amount * max_fee_bps as i128 / 10_000;
        // Destination caller left empty on purpose: it restricts who may submit
        // the receive on the far chain, and restricting it to an address whose
        // key might be lost turns a recoverable delay into a permanent one. The
        // message is useless to anyone else, because it mints to the stored
        // recipient regardless of who relays it.
        let anyone = BytesN::from_array(&e, &[0u8; 32]);
        TokenMessengerClient::new(&e, &messenger).deposit_for_burn(
            &here,
            &amount,
            &domain,
            &recipient,
            &usdc,
            &anyone,
            &max_fee,
            &1000u32,
        );

        let exposure = Self::get_exposure(e.clone()) + amount;
        e.storage().instance().set(&Cfg::Exposure, &exposure);
        Self::bump(&e);
        Burned {
            domain,
            amount,
            recipient,
            exposure,
        }
        .publish(&e);
        Ok(())
    }

    /// Book capital that has come back from the far chain home to the Vault.
    ///
    /// The balance is checked first, and that check is the point of this
    /// function. Capital returning is a crossing initiated on the far chain
    /// that lands here as an ordinary mint, with nothing on Stellar able to
    /// tell whether it is on its way or was never sent. Deallocating against
    /// money that has not arrived would decrement the Engine's book, report the
    /// Vault repaid, and then panic in the transfer or, worse, succeed by
    /// spending a different crossing's funds.
    pub fn deallocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::ExposureUnderflow);
        }
        let usdc: Address = Self::cfg(&e, &Cfg::Usdc)?;
        let vault: Address = Self::cfg(&e, &Cfg::Vault)?;
        let token = TokenClient::new(&e, &usdc);
        if token.balance(&e.current_contract_address()) < amount {
            return Err(AdapterError::ReturnNotArrived);
        }
        token.transfer(&e.current_contract_address(), &vault, &amount);
        let exposure = exposure - amount;
        e.storage().instance().set(&Cfg::Exposure, &exposure);
        Self::bump(&e);
        Returned {
            vault,
            amount,
            exposure,
        }
        .publish(&e);
        Ok(())
    }

    /// Recognise exposure that is not coming back.
    ///
    /// The ordinary path for this pool and not the distress path. Two crossings
    /// cost two of Circle's fees and the decimals differ in both directions, so
    /// the amount that can ever be deallocated is strictly less than the amount
    /// burned. That shortfall is a real loss of principal and it is written
    /// down rather than absorbed by a `deallocate` that stopped checking.
    pub fn write_down(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::WriteDownExceedsExposure);
        }
        let exposure = exposure - amount;
        e.storage().instance().set(&Cfg::Exposure, &exposure);
        Self::bump(&e);
        WrittenDown { amount, exposure }.publish(&e);
        Ok(())
    }

    /// Send USDC held above the booked exposure to the stored Vault.
    ///
    /// The destination is read from storage and is not a parameter, which is
    /// what makes this a way home for stranded capital rather than a
    /// withdrawal. It matters more here than on a local adapter: a return
    /// crossing lands on this balance unannounced, and if the Engine's admin
    /// never deallocates it, this is how it gets home.
    pub fn recover_surplus(e: Env, caller: Address) -> Result<i128, AdapterError> {
        caller.require_auth();
        let engine: Address = Self::cfg(&e, &Cfg::Engine)?;
        let admin: Address = Self::cfg(&e, &Cfg::Admin)?;
        if caller != engine && caller != admin {
            return Err(AdapterError::NotAuthorized);
        }
        let usdc: Address = Self::cfg(&e, &Cfg::Usdc)?;
        let vault: Address = Self::cfg(&e, &Cfg::Vault)?;
        let token = TokenClient::new(&e, &usdc);
        let held = token.balance(&e.current_contract_address());
        let surplus = held - Self::get_exposure(e.clone());
        if surplus <= 0 {
            return Err(AdapterError::NothingToRecover);
        }
        token.transfer(&e.current_contract_address(), &vault, &surplus);
        Self::bump(&e);
        SurplusRecovered {
            vault,
            amount: surplus,
        }
        .publish(&e);
        Ok(surplus)
    }

    /// Repoint the crossing, refused while anything is deployed.
    ///
    /// The lock is the whole safety property. Exposure booked here is a claim
    /// on capital at the old destination; moving the pointer while it stands
    /// would leave the book saying one thing and the money sitting at another
    /// address, with the next return arriving from a place the adapter no
    /// longer names.
    pub fn set_destination(
        e: Env,
        admin: Address,
        domain: u32,
        recipient: BytesN<32>,
    ) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        if Self::get_exposure(e.clone()) != 0 {
            return Err(AdapterError::DestinationLocked);
        }
        Self::require_recipient(&recipient)?;
        e.storage().instance().set(&Cfg::Domain, &domain);
        e.storage().instance().set(&Cfg::Recipient, &recipient);
        Self::bump(&e);
        DestinationSet { domain, recipient }.publish(&e);
        Ok(())
    }

    pub fn set_counterparties(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
    ) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        Self::require_empty(&e)?;
        let usdc: Address = Self::cfg(&e, &Cfg::Usdc)?;
        Self::require_symmetry(&e, &engine, &vault, &usdc)?;
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        Self::bump(&e);
        CounterpartiesSet { engine, vault }.publish(&e);
        Ok(())
    }

    pub fn get_exposure(e: Env) -> i128 {
        e.storage()
            .instance()
            .get(&Cfg::Exposure)
            .unwrap_or(0i128)
    }

    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), AdapterError> {
        new_admin.require_auth();
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(AdapterError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(AdapterError::NotPendingAdmin);
        }
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        Self::bump(&e);
        AdminChanged { admin: new_admin }.publish(&e);
        Ok(())
    }

    pub fn pending_admin(e: Env) -> Option<Address> {
        e.storage().instance().get(&Cfg::PendingAdmin)
    }

    pub fn pool_kind(_e: Env) -> Symbol {
        symbol_short!("crosschn")
    }

    /// The feed this pool is priced from. The same private credit NAV the book
    /// on the far chain reports, because that is what the capital bought: the
    /// crossing is transport, not an asset with a price of its own.
    pub fn oracle_feed(_e: Env) -> Symbol {
        symbol_short!("PC_NAV")
    }

    /// Minimum and maximum settlement, in days. A crossing attests in seconds,
    /// and then the capital sits in an order that the far side's operator
    /// settles on their own schedule, which is the part that takes a week.
    pub fn settlement_window(_e: Env) -> (u32, u32) {
        (1, 14)
    }

    pub fn engine(e: Env) -> Result<Address, AdapterError> {
        Self::cfg(&e, &Cfg::Engine)
    }

    pub fn usdc(e: Env) -> Result<Address, AdapterError> {
        Self::cfg(&e, &Cfg::Usdc)
    }

    pub fn vault(e: Env) -> Result<Address, AdapterError> {
        Self::cfg(&e, &Cfg::Vault)
    }

    pub fn admin(e: Env) -> Result<Address, AdapterError> {
        Self::cfg(&e, &Cfg::Admin)
    }

    pub fn messenger(e: Env) -> Result<Address, AdapterError> {
        Self::cfg(&e, &Cfg::Messenger)
    }

    pub fn destination(e: Env) -> Result<(u32, BytesN<32>), AdapterError> {
        let domain: u32 = e
            .storage()
            .instance()
            .get(&Cfg::Domain)
            .ok_or(AdapterError::NotInitialized)?;
        Ok((domain, Self::cfg(&e, &Cfg::Recipient)?))
    }

    // -----------------------------------------------------------------------

    fn cfg<T: soroban_sdk::TryFromVal<Env, soroban_sdk::Val>>(
        e: &Env,
        key: &Cfg,
    ) -> Result<T, AdapterError> {
        e.storage()
            .instance()
            .get(key)
            .ok_or(AdapterError::NotInitialized)
    }

    fn require_engine(e: &Env) -> Result<(), AdapterError> {
        let engine: Address = Self::cfg(e, &Cfg::Engine)?;
        engine.require_auth();
        Ok(())
    }

    fn require_admin(e: &Env, admin: &Address) -> Result<(), AdapterError> {
        let stored: Address = Self::cfg(e, &Cfg::Admin)?;
        if stored != *admin {
            return Err(AdapterError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    fn require_empty(e: &Env) -> Result<(), AdapterError> {
        if Self::get_exposure(e.clone()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        let usdc: Address = Self::cfg(e, &Cfg::Usdc)?;
        if TokenClient::new(e, &usdc).balance(&e.current_contract_address()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        Ok(())
    }

    /// The Engine offered has to answer that it governs the Vault offered, and
    /// the Vault has to custody the asset this adapter transfers with.
    fn require_symmetry(
        e: &Env,
        engine: &Address,
        vault: &Address,
        usdc: &Address,
    ) -> Result<(), AdapterError> {
        if EngineClient::new(e, engine).vault() != *vault {
            return Err(AdapterError::CounterpartyMismatch);
        }
        if VaultClient::new(e, vault).usdc() != *usdc {
            return Err(AdapterError::CounterpartyMismatch);
        }
        Ok(())
    }

    /// Thirty two zero bytes is a destination CCTP accepts and nobody holds.
    fn require_recipient(recipient: &BytesN<32>) -> Result<(), AdapterError> {
        if recipient.to_array() == [0u8; 32] {
            return Err(AdapterError::InvalidMintRecipient);
        }
        Ok(())
    }

    fn bump(e: &Env) {
        e.storage().instance().extend_ttl(30 * DAY, 30 * DAY);
    }
}

#[cfg(test)]
mod test;
