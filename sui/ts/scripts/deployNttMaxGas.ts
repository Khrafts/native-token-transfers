#!/usr/bin/env node

import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load .env from the parent directory (where it's located)
dotenv.config({ path: path.join(__dirname, '..', '.env') });

async function deployNttMaxGas() {
  console.log('🚀 Deploying NTT package with maximum gas limit...\n');

  // Initialize Sui client
  const client = new SuiClient({
    url: process.env['SUI_RPC_URL'] || 'https://fullnode.testnet.sui.io:443'
  });

  // Get deployer keypair
  let deployer;
  try {
    if (process.env['SUI_PRIVATE_KEY']) {
      if (process.env['SUI_PRIVATE_KEY']!.startsWith('suiprivkey1')) {
        deployer = Ed25519Keypair.fromSecretKey(process.env['SUI_PRIVATE_KEY']!);
      } else {
        const privateKeyHex = process.env['SUI_PRIVATE_KEY']!.replace('0x', '');
        deployer = Ed25519Keypair.fromSecretKey(new Uint8Array(Buffer.from(privateKeyHex, 'hex')));
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

  // Load portal deployment result
  let portalResult;
  try {
    const portalData = fs.readFileSync(path.join(__dirname, '../partial-deployment-result.json'), 'utf8');
    portalResult = JSON.parse(portalData);
    console.log('📦 Loaded portal package:', portalResult.portal.packageId);
  } catch (error) {
    console.error('❌ Failed to load portal deployment result:', error);
    return;
  }

  try {
    // Deploy NTT package
    console.log('\n🚀 Deploying NTT package with maximum gas limit...');

    const nttPath = path.join(__dirname, '../../packages/ntt');
    const nttBuildDir = path.join(nttPath, 'build');
    const nttPackageDirs = fs.readdirSync(nttBuildDir).filter(f => f !== 'locks');
    const nttPackageName = nttPackageDirs[0];

    if (!nttPackageName) {
      throw new Error('No compiled NTT package found');
    }

    const nttModulesPath = path.join(nttBuildDir, nttPackageName, 'bytecode_modules');
    const moduleFiles = fs.readdirSync(nttModulesPath)
      .filter(f => f.endsWith('.mv'));

    console.log(`📦 Found ${moduleFiles.length} modules in NTT package:`);

    // Load modules with size info
    const nttModules = moduleFiles.map(f => {
      const filePath = path.join(nttModulesPath, f);
      const stats = fs.statSync(filePath);
      const data = fs.readFileSync(filePath).toString('base64');
      return {
        name: f,
        size: stats.size,
        data: data
      };
    });

    // Log module sizes for debugging
    const totalSize = nttModules.reduce((sum, m) => sum + m.size, 0);
    console.log(`📊 Total package size: ${(totalSize / 1024).toFixed(2)} KB`);
    nttModules.forEach(m => {
      console.log(`   - ${m.name}: ${(m.size / 1024).toFixed(2)} KB`);
    });

    // Dependencies - minimal set to reduce size
    const dependencies = [
      '0x1', // Sui system
      '0x2', // MoveStdlib
      portalResult.portal.packageId, // Portal
      '0x5306f64e312b581766351c07af79c72fcb1cd25147157fdc2f8ad76de9a3fb6a', // Wormhole core
    ];

    console.log('🔗 Using dependencies:', dependencies);

    // Create transaction with maximum possible gas budget
    const nttTx = new Transaction();

    // Set extremely high gas budget (1 billion MIST = 1 SUI)
    nttTx.setGasBudget(1_000_000_000);

    // Publish the package
    const [nttUpgradeCap] = nttTx.publish({
      modules: nttModules.map(m => m.data),
      dependencies: dependencies
    });

    nttTx.transferObjects([nttUpgradeCap], deployer.toSuiAddress());

    console.log('📤 Publishing NTT package...');
    console.log('⚡ Gas budget: 1,000,000,000 MIST (1 SUI)');
    console.log('⏳ This is a maximum gas attempt - please wait...');

    const startTime = Date.now();

    const nttResult = await client.signAndExecuteTransaction({
      signer: deployer,
      transaction: nttTx,
      options: {
        showEffects: true,
        showObjectChanges: true,
        showEvents: true
      }
    });

    const endTime = Date.now();
    console.log(`⏱️  Transaction took ${((endTime - startTime) / 1000).toFixed(1)} seconds`);

    if (nttResult.effects?.status.status !== 'success') {
      console.error('❌ Transaction failed:', nttResult.effects?.status);
      throw new Error(`NTT deployment failed: ${nttResult.effects?.status.error || 'Unknown error'}`);
    }

    console.log('✅ Transaction executed successfully!');
    console.log('📄 Transaction digest:', nttResult.digest);

    // Extract package ID and upgrade cap
    let nttPackageId = '';
    let nttUpgradeCapId = '';

    if (nttResult.objectChanges) {
      console.log('🔍 Extracting objects from transaction...');
      for (const change of nttResult.objectChanges) {
        if (change.type === 'published') {
          nttPackageId = change.packageId;
          console.log(`✅ Found published package: ${nttPackageId}`);
        } else if (change.type === 'created' && change.objectType?.includes('UpgradeCap')) {
          nttUpgradeCapId = change.objectId;
          console.log(`✅ Found upgrade cap: ${nttUpgradeCapId}`);
        }
      }
    }

    if (!nttPackageId) {
      throw new Error('Failed to extract NTT package ID from transaction result');
    }

    console.log(`🎉 NTT package deployed successfully!`);
    console.log(`📦 Package ID: ${nttPackageId}`);
    console.log(`🔧 Upgrade Cap: ${nttUpgradeCapId || 'Not found'}`);

    // Complete deployment result
    const deploymentResult = {
      portal: portalResult.portal,
      ntt: {
        packageId: nttPackageId,
        upgradeCapId: nttUpgradeCapId,
        transactionDigest: nttResult.digest
      }
    };

    // Save result
    fs.writeFileSync(path.join(__dirname, '../deployment-result.json'), JSON.stringify(deploymentResult, null, 2));
    console.log('\n🎉 Complete deployment success!');
    console.log('📄 Deployment result saved to: ./deployment-result.json');
    console.log('\n📋 Final Deployment Summary:');
    console.log(JSON.stringify(deploymentResult, null, 2));

    console.log('\n✅ All packages deployed successfully!');
    console.log('🔧 Ready for M Token NTT State setup!');

  } catch (error) {
    console.error('❌ NTT deployment failed:', error);

    if (error.message.includes('504')) {
      console.log('\n💡 Network timeout occurred. This suggests:');
      console.log('1. The package is still too large even with high gas');
      console.log('2. Network congestion or RPC limits');
      console.log('3. Consider deploying during off-peak hours');
    } else if (error.message.includes('gas')) {
      console.log('\n💡 Gas-related error. Try:');
      console.log('1. Adding more SUI to the deployer address');
      console.log('2. Using an even higher gas budget');
    } else {
      console.log('\n💡 Other error. Check network connectivity and try again.');
    }

    // Save error status
    const resultPath = path.join(__dirname, '../deployment-result.json');
    if (!fs.existsSync(resultPath)) {
      fs.writeFileSync(resultPath, JSON.stringify({
        ...portalResult,
        ntt: {
          error: 'Deployment failed',
          details: error.message,
          timestamp: new Date().toISOString()
        }
      }, null, 2));
      console.log('📄 Error status saved to: ./deployment-result.json');
    }
  }
}

deployNttMaxGas().catch(console.error);