import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import { Bonjour, type Service } from 'bonjour-service';
import type { DeviceCandidate, PairedDevice } from '../../src/shared/types';
import { parseDeviceInfo, SmartCastClient } from './SmartCastClient';
import { normalizeMacAddress } from './WakeOnLanService';

interface DiscoveryHint {
  source: DeviceCandidate['source'];
  macAddress?: string;
}

export class DiscoveryService {
  async discover(cached: PairedDevice | null, manualAddress = ''): Promise<DeviceCandidate[]> {
    const sources = new Map<string, DiscoveryHint>();
    if (cached?.address) sources.set(cached.address, { source: 'cached', macAddress: cached.macAddress });
    if (isIpv4(manualAddress)) sources.set(manualAddress, { source: 'manual' });

    const bonjour = new Bonjour();
    const onService = (service: Service) => {
      // Google Cast announcements are also accepted and verified on Vizio's
      // control port; some firmware advertises only a user-assigned TV name.
      const macAddress = serviceMacAddress(service);
      for (const address of service.addresses ?? []) {
        if (isIpv4(address)) sources.set(address, { source: 'mdns', macAddress });
      }
    };

    const browsers = [
      bonjour.find({ type: 'viziocast', protocol: 'tcp' }, onService),
      bonjour.find({ type: 'googlecast', protocol: 'tcp' }, onService),
      bonjour.find({ type: 'airplay', protocol: 'tcp' }, onService),
    ];
    await delay(3200);
    browsers.forEach((browser) => browser.stop());
    bonjour.destroy();

    const candidates = await Promise.all(
      [...sources.entries()].map(([address, hint]) => this.probe(address, hint.source, hint.macAddress).catch(() => null)),
    );
    return candidates
      .filter((candidate): candidate is DeviceCandidate => Boolean(candidate))
      .sort((left, right) => left.name.localeCompare(right.name));
  }

  async probe(address: string, source: DeviceCandidate['source'], macHint?: string): Promise<DeviceCandidate> {
    if (!isIpv4(address)) throw new Error('Enter a valid IPv4 address.');
    await assertPort(address, 7345, 1800);
    const client = new SmartCastClient(address);
    const [deviceInfo, fingerprint] = await Promise.all([
      client.getDeviceInfo(),
      client.getCertificateFingerprint(),
    ]);
    const parsed = parseDeviceInfo(deviceInfo);
    const identity = parsed.serial || fingerprint || address;
    const macAddress = normalizeMacAddress(macHint) ?? await this.resolveMacAddress(address);
    return {
      id: createHash('sha256').update(identity).digest('hex').slice(0, 16),
      name: parsed.name || 'Vizio TV',
      address,
      model: parsed.model,
      serial: parsed.serial,
      fingerprint,
      macAddress,
      source,
    };
  }

  async resolveMacAddress(address: string) {
    if (!isIpv4(address) || process.platform !== 'win32') return undefined;
    const systemRoot = process.env.SystemRoot;
    if (!systemRoot || !path.isAbsolute(systemRoot)) return undefined;
    const executable = path.join(systemRoot, 'System32', 'arp.exe');
    const output = await runArp(executable, address).catch(() => '');
    return parseArpMac(output, address);
  }
}

export function parseArpMac(output: string, address: string) {
  if (!isIpv4(address)) return undefined;
  const escaped = address.replaceAll('.', '\\.');
  const match = output.match(new RegExp(`(?:^|\\s)${escaped}\\s+([a-fA-F0-9:-]{17})(?:\\s|$)`, 'm'));
  return normalizeMacAddress(match?.[1]);
}

function serviceMacAddress(service: Service) {
  const txt = (service.txt ?? {}) as Record<string, unknown>;
  return [txt.deviceid, txt.deviceId, txt.mac, txt.macAddress]
    .map(normalizeMacAddress)
    .find(Boolean);
}

function runArp(executable: string, address: string) {
  return new Promise<string>((resolve, reject) => {
    execFile(executable, ['-a', address], { timeout: 1_500, windowsHide: true }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}

function assertPort(host: string, port: number, timeoutMs: number) {
  return new Promise<void>((resolve, reject) => {
    const socket = net.createConnection({ host, port });
    const timer = setTimeout(() => socket.destroy(new Error('Connection timed out.')), timeoutMs);
    socket.once('connect', () => {
      clearTimeout(timer);
      socket.end();
      resolve();
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function isIpv4(value: string) {
  return net.isIPv4(value.trim());
}

function delay(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
