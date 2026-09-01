use crate::state::GatewayAccountMeta;

/// Encode a u64 as big-endian bytes for TSS message construction.
#[inline]
pub fn encode_u64_be(value: u64) -> [u8; 8] {
    value.to_be_bytes()
}

/// Serialize gateway accounts into a length-prefixed buffer for TSS signing.
/// Format: [u32 BE count][pubkey(32) + writable(1)] × N
pub fn serialize_gateway_accounts(accounts: &[GatewayAccountMeta]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(4 + accounts.len() * 33);
    buf.extend_from_slice(&(accounts.len() as u32).to_be_bytes());
    for acc in accounts {
        buf.extend_from_slice(&acc.pubkey.to_bytes());
        buf.push(if acc.is_writable { 1 } else { 0 });
    }
    buf
}

/// Serialize instruction data into a length-prefixed buffer for TSS signing.
/// Format: [u32 BE length][bytes]
pub fn serialize_ix_data(ix_data: &[u8]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(4 + ix_data.len());
    buf.extend_from_slice(&(ix_data.len() as u32).to_be_bytes());
    buf.extend_from_slice(ix_data);
    buf
}

/// Serialize a UTF-8 string into a u32-length-prefixed buffer for signature binding.
pub fn serialize_string(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    let mut buf = Vec::with_capacity(4 + bytes.len());
    buf.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    buf.extend_from_slice(bytes);
    buf
}
