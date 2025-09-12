use crate::errors::GatewayError;
use crate::state::{Config, UniversalPayload, FEED_ID};
use anchor_lang::prelude::*;
use pyth_solana_receiver_sdk::price_update::{get_feed_id_from_hex, PriceUpdateV2};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PriceData {
    pub price: i64,        // Raw price from Pyth
    pub exponent: i32,     // Exponent to apply
    pub publish_time: i64, // When the price was published
    pub confidence: u64,   // Price confidence interval
}

pub fn calculate_sol_price(price_update: &Account<PriceUpdateV2>) -> Result<PriceData> {
    let price = price_update
        .get_price_unchecked(&get_feed_id_from_hex(FEED_ID)?) //TODO check time in mainnet
        .map_err(|_| error!(GatewayError::InvalidPrice))?;

    require!(price.price > 0, GatewayError::InvalidPrice);

    Ok(PriceData {
        price: price.price,
        exponent: price.exponent,
        publish_time: price.publish_time,
        confidence: price.conf,
    })
}

// Convert lamports (1e9) to USD using Pyth price (price + exponent)
pub fn lamports_to_usd_amount_i128(lamports: u64, price: &PriceData) -> i128 {
    // Keep same approach as locker (raw integer with exponent)
    let sol_amount_f64 = lamports as f64 / 1_000_000_000.0;
    let price_f64 = price.price as f64;
    (sol_amount_f64 * price_f64).round() as i128
}

// Check USD caps for gas deposits (matching ETH contract logic) with Pyth oracle
pub fn check_usd_caps_with_pyth(
    config: &Config,
    lamports: u64,
    price_data: &PriceData,
) -> Result<()> {
    // Calculate USD equivalent using Pyth price (same logic as locker)
    let sol_amount_f64 = lamports as f64 / 1_000_000_000.0; // Convert lamports to SOL
    let price_f64 = price_data.price as f64;
    let usd_amount_raw = (sol_amount_f64 * price_f64).round() as i128;

    // Convert to 8 decimal precision for config comparison
    // Pyth typically uses -8 exponent, so we need to adjust
    let usd_amount_8dec = if price_data.exponent >= -8 {
        // If exponent is -8 or higher, we need to scale down
        let scale_factor = 10_i128.pow((price_data.exponent + 8) as u32);
        (usd_amount_raw / scale_factor) as u128
    } else {
        // If exponent is lower than -8, we need to scale up
        let scale_factor = 10_i128.pow((-8 - price_data.exponent) as u32);
        (usd_amount_raw * scale_factor) as u128
    };

    require!(
        usd_amount_8dec >= config.min_cap_universal_tx_usd,
        GatewayError::BelowMinCap
    );
    require!(
        usd_amount_8dec <= config.max_cap_universal_tx_usd,
        GatewayError::AboveMaxCap
    );

    Ok(())
}

// Check USD caps for gas deposits - ONLY Pyth, no fallback
pub fn check_usd_caps(
    config: &Config,
    lamports: u64,
    price_update: &Account<PriceUpdateV2>,
) -> Result<()> {
    // Get real-time SOL price from Pyth oracle (exactly like locker)
    let price_data = calculate_sol_price(price_update)?;

    // Use the Pyth function for USD cap check
    check_usd_caps_with_pyth(config, lamports, &price_data)
}

// Calculate payload hash (matching ETH contract keccak256(abi.encode(payload)))
pub fn payload_hash(payload: &UniversalPayload) -> [u8; 32] {
    // Use Solana's sha256 to hash the serialized payload (closest to keccak256)
    let serialized = payload.try_to_vec().unwrap_or_default();
    anchor_lang::solana_program::hash::hash(&serialized).to_bytes()
}

// Convert payload to bytes (matching ETH contract)
pub fn payload_to_bytes(payload: &UniversalPayload) -> Vec<u8> {
    payload.try_to_vec().unwrap_or_default()
}
