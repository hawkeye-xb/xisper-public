// ESM wrapper for CommonJS native module
import { createRequire } from 'module';
const require = createRequire(import.meta.url);

const nativeModule = require('./index.js');

export const startMonitor = nativeModule.startMonitor;
export const stopMonitor = nativeModule.stopMonitor;
export const isMonitorRunning = nativeModule.isMonitorRunning;

