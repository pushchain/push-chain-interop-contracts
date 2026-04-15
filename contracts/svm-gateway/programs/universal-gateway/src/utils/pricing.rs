use crate::errors::GatewayError;
use crate::state::{Config, FEED_ID};
use anchor_lang::prelude::*;
use pyth_solana_receiver_sdk::price_update::{get_feed_id_from_hex, PriceUpdateV2};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PriceData {
    pub price: i64,        // Raw price from Pyth
    pub exponent: i32,     // Exponent to apply
    pub publish_time: i64, // When the price was published
    pub confidence: u64,   // Price confidence interval
}

pub fn calculate_sol_price(
    price_update: &Account<PriceUpdateV2>,
    max_age_seconds: u64,
) -> Result<PriceData> {
    let feed_id = get_feed_id_from_hex(FEED_ID).map_err(|_| error!(GatewayError::InvalidPrice))?;
    let clock = Clock::get()?;
    let price = price_update
        .get_price_no_older_than(&clock, max_age_seconds, &feed_id)
        .map_err(|_| error!(GatewayError::InvalidPrice))?;

    require!(price.price > 0, GatewayError::InvalidPrice);

    Ok(PriceData {
        price: price.price,
        exponent: price.exponent,
        publish_time: price.publish_time,
        confidence: price.conf,
    })
}

/// Calculate USD amount from SOL amount using price data (matching EVM implementation)
/// @dev Pyth price format: actual_price = price * 10^exponent
///      For SOL/USD: price = 15025000000, exponent = -8 → actual_price = 150.25 USD
///      Result is in 8 decimals (matching EVM's 18 decimals but scaled to 8 for consistency)
///      Formula: USD_8dec = (lamports * price * 10^(exponent + 8)) / 1e9
pub fn calculate_usd_amount(lamports: u64, price_data: &PriceData) -> Result<u128> {
    let lamports_u128 = lamports as u128;
    let price_u128 = price_data.price as u128;

    // Multiply first to preserve precision, then apply exponent adjustment
    // For exponent = -8: we need to multiply by 10^(exponent + 8) = 10^0 = 1
    let product = lamports_u128
        .checked_mul(price_u128)
        .ok_or(GatewayError::InvalidAmount)?;

    // Apply exponent: multiply by 10^(exponent + 8) to get result in 8 decimals
    let exponent_adjustment = (price_data.exponent + 8) as i32;

    let usd_amount = if exponent_adjustment >= 0 {
        product
            .checked_mul(10u128.pow(exponent_adjustment as u32))
            .and_then(|x| x.checked_div(1_000_000_000))
            .ok_or(GatewayError::InvalidAmount)?
    } else {
        product
            .checked_div(10u128.pow((-exponent_adjustment) as u32))
            .and_then(|x| x.checked_div(1_000_000_000))
            .ok_or(GatewayError::InvalidAmount)?
    };

    Ok(usd_amount)
}

// Check USD caps for gas deposits using the integer-safe path
pub fn check_usd_caps(
    config: &Config,
    lamports: u64,
    price_update: &Account<PriceUpdateV2>,
) -> Result<u128> {
    // Fallback to 60 s when the stored value is 0 (existing accounts before the field was added).
    let max_age = if config.pyth_max_age_seconds == 0 { 60 } else { config.pyth_max_age_seconds };
    let price_data = calculate_sol_price(price_update, max_age)?;
    if config.pyth_confidence_threshold > 0 {
        require!(
            price_data.confidence <= config.pyth_confidence_threshold,
            GatewayError::InvalidPrice
        );
    }
    let usd_amount = calculate_usd_amount(lamports, &price_data)?;
    require!(
        usd_amount >= config.min_cap_universal_tx_usd,
        GatewayError::BelowMinCap
    );
    require!(
        usd_amount <= config.max_cap_universal_tx_usd,
        GatewayError::AboveMaxCap
    );
    Ok(usd_amount)
}

/// View function for SOL price (display only — not part of cap enforcement).
/// Uses a 1-hour window since this path does not gate any protocol limit.
pub fn get_sol_price(price_update: &Account<PriceUpdateV2>) -> Result<PriceData> {
    calculate_sol_price(price_update, 3_600)
}
