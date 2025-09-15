#!/usr/bin/env node

import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

async function testMTokenDeployment() {
  console.log('🚀 Testing M Token NTT Deployment...\n');

  // Initialize Sui client
  const client = new SuiClient({
    url: process.env['SUI_RPC_URL'] || 'https://fullnode.testnet.sui.io:443'
  });

  // Get deployer keypair from environment
  let deployer: Ed25519Keypair;

  if (process.env['SUI_PRIVATE_KEY']) {
    try {
      // Handle base64 format (sui client export format)
      if (process.env['SUI_PRIVATE_KEY']!.startsWith('suiprivkey1')) {
        deployer = Ed25519Keypair.fromSecretKey(
          new Uint8Array(Buffer.from(process.env['SUI_PRIVATE_KEY']!.split('suiprivkey1')[1], 'base64'))
        );
      } else {
        // Handle hex format
        const privateKeyHex = process.env['SUI_PRIVATE_KEY']!.replace('0x', '');
        deployer = Ed25519Keypair.fromSecretKey(
          new Uint8Array(Buffer.from(privateKeyHex, 'hex'))
        );
      }

      console.log('✅ Deployer keypair loaded successfully');
      console.log('📝 Deployer address:', deployer.toSuiAddress());
    } catch (error) {
      console.error('❌ Failed to load deployer keypair:', error);
      return;
    }
  } else {
    console.error('❌ SUI_PRIVATE_KEY not found in environment variables');
    return;
  }

  // Check deployer balance
  try {
    const balance = await client.getBalance({
      owner: deployer.toSuiAddress(),
    });

    console.log('💰 Deployer balance:', parseInt(balance.totalBalance) / 1000000000, 'SUI');

    if (parseInt(balance.totalBalance) < 1000000000) {
      console.warn('⚠️  Low balance! Deployment might fail. Please ensure you have at least 1 SUI.');
    }
  } catch (error) {
    console.error('❌ Failed to check balance:', error);
  }

  // Test basic transaction to ensure keypair works
  try {
    console.log('\n🔧 Testing basic transaction...');

    const tx = new Transaction();
    tx.setGasBudget(10000000);

    // Simple transfer to self to test the keypair
    const [coin] = tx.splitCoins(tx.gas, [1000]);
    tx.transferObjects([coin], deployer.toSuiAddress());

    const result = await client.signAndExecuteTransaction({
      signer: deployer,
      transaction: tx,
      options: {
        showEffects: true,
      }
    });

    console.log('✅ Basic transaction successful!');
    console.log('📄 Transaction digest:', result.digest);

  } catch (error) {
    console.error('❌ Basic transaction failed:', error);
    return;
  }

  console.log('\n🎯 Environment setup complete!');
  console.log('✅ Sui client connected');
  console.log('✅ Deployer keypair loaded');
  console.log('✅ Basic transaction successful');
  console.log('\n📋 Ready for M Token NTT deployment!');

  console.log('\n📦 Move packages status:');
  try {
    // Check if packages are already built
    const fs = await import('fs');
    const path = await import('path');

    const nttBuildPath = path.join(process.cwd(), '..', 'packages', 'ntt', 'build');
    const portalBuildPath = path.join(process.cwd(), '..', 'packages', 'portal', 'build');

    if (fs.existsSync(nttBuildPath)) {
      console.log('✅ NTT package: Built');
    } else {
      console.log('❌ NTT package: Not built');
    }

    if (fs.existsSync(portalBuildPath)) {
      console.log('✅ Portal package: Built');
    } else {
      console.log('❌ Portal package: Not built');
    }

  } catch (error) {
    console.log('❓ Could not check package build status');
  }
}

// Run the test
testMTokenDeployment().catch(console.error);