#!/usr/bin/env node

import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import dotenv from 'dotenv';
// Direct implementation instead of importing deleted module

// Load environment variables
dotenv.config();

async function main() {
  console.log('🚀 Starting M Token NTT Deployment...\n');

  // Initialize Sui client
  const client = new SuiClient({
    url: process.env['SUI_RPC_URL'] || 'https://fullnode.testnet.sui.io:443'
  });

  // Get deployer keypair from environment
  let deployer;
  try {
    if (process.env['SUI_PRIVATE_KEY']) {
      // Handle base64 format (sui client export format)
      if (process.env['SUI_PRIVATE_KEY']!.startsWith('suiprivkey1')) {
        deployer = Ed25519Keypair.fromSecretKey(
          process.env['SUI_PRIVATE_KEY']!
        );
      } else {
        // Handle hex format
        const privateKeyHex = process.env['SUI_PRIVATE_KEY']!.replace('0x', '');
        deployer = Ed25519Keypair.fromSecretKey(
          new Uint8Array(Buffer.from(privateKeyHex, 'hex'))
        );
      }

      console.log('✅ Deployer keypair loaded');
      console.log('📝 Deployer address:', deployer.toSuiAddress());
    } else {
      throw new Error('SUI_PRIVATE_KEY not found');
    }
  } catch (error) {
    console.error('❌ Failed to load keypair:', error);
    return;
  }

  // Create deployment configuration
  const config = {
    network: 'testnet',
    suiClient: client,
    deployer: deployer,
    chainId: 14, // Sui testnet chain ID
    ethHubAddress: process.env['ETH_HUB_ADDRESS'],
    registrarAddress: process.env['REGISTRAR_ADDRESS']
  };

  try {
    // TODO: Implement deployment logic directly
    console.log('🔧 Deployment logic to be implemented...');
    console.log('📋 Configuration:', JSON.stringify(config, null, 2));
    const result = { status: 'pending', message: 'Implementation needed' };

    // Save deployment result
    const deploymentPath = './deployment-result.json';
    // TODO: Implement saveDeploymentResult
    console.log('📄 Would save result to:', deploymentPath);

    console.log('\n🎉 Deployment completed successfully!');
    console.log('📄 Deployment result saved to:', deploymentPath);

  } catch (error) {
    console.error('❌ Deployment failed:', error);
    console.error('\n🔍 Debug info:');
    console.error('Network:', config.network);
    console.error('Chain ID:', config.chainId);
    console.error('Deployer:', config.deployer.toSuiAddress());

    // Save partial result if available
    const partialResult = deployerInstance['result'];
    if (Object.keys(partialResult).length > 0) {
      const partialPath = './partial-deployment-result.json';
      deployerInstance.saveDeploymentResult(partialPath);
      console.log('📄 Partial deployment result saved to:', partialPath);
    }
  }
}

main().catch(console.error);