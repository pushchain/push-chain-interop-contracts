
import bs58 from 'bs58';
import fs from 'fs';

// Replace with your Phantom Base58 secret key string
const base58Secret = '4mUqAnRi1MbJZUZj3dQUWb1tvt8vo9xrcaXHi3VFgezYCLnQQG8u7NwuvoY6ekVkdg46BkVa3hdi5VZF658eszsP';

const secretKey = bs58.decode(base58Secret);

// Convert to JSON format
fs.writeFileSync('phantom-keypair.json', JSON.stringify(Array.from(secretKey)));

console.log('✅ Saved phantom-keypair.json successfully.');
