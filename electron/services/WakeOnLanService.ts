import dgram from 'node:dgram';
import os from 'node:os';

const WAKE_PORTS = [9, 7] as const;

export class WakeOnLanService {
  async wake(macAddress: string, cachedAddress?: string) {
    const packet = buildMagicPacket(macAddress);
    const hosts = new Set<string>(['255.255.255.255', ...localBroadcastAddresses(os.networkInterfaces(), cachedAddress)]);
    if (cachedAddress && isIpv4(cachedAddress)) hosts.add(cachedAddress);

    // A few short bursts are more reliable with sleeping Wi-Fi chipsets while
    // remaining a tiny, LAN-only packet sequence.
    for (let burst = 0; burst < 3; burst += 1) {
      await Promise.all(
        [...hosts].flatMap((host) => WAKE_PORTS.map((port) => sendPacket(packet, host, port))),
      );
      if (burst < 2) await delay(140);
    }
  }
}

export function normalizeMacAddress(value: unknown) {
  if (typeof value !== 'string') return undefined;
  const compact = value.replace(/[^a-fA-F0-9]/g, '').toUpperCase();
  if (!/^[A-F0-9]{12}$/.test(compact) || compact === '000000000000' || compact === 'FFFFFFFFFFFF') return undefined;
  const firstByte = Number.parseInt(compact.slice(0, 2), 16);
  if ((firstByte & 1) === 1) return undefined;
  return compact.match(/.{2}/g)?.join(':');
}

export function buildMagicPacket(macAddress: string) {
  const normalized = normalizeMacAddress(macAddress);
  if (!normalized) throw new Error('TV does not have a valid network adapter address for wake-up.');
  const mac = Buffer.from(normalized.replaceAll(':', ''), 'hex');
  return Buffer.concat([Buffer.alloc(6, 0xff), ...Array.from({ length: 16 }, () => mac)]);
}

export function localBroadcastAddresses(interfaces = os.networkInterfaces(), targetAddress?: string) {
  const broadcasts = new Set<string>();
  for (const records of Object.values(interfaces)) {
    for (const record of records ?? []) {
      if (record.family !== 'IPv4' || record.internal || !isIpv4(record.address)) continue;
      const prefixLength = Number(record.cidr?.split('/')[1] ?? 24);
      if (!Number.isInteger(prefixLength) || prefixLength < 1 || prefixLength > 30) continue;
      const address = ipv4ToNumber(record.address);
      const mask = (0xffffffff << (32 - prefixLength)) >>> 0;
      if (targetAddress && isIpv4(targetAddress) && (ipv4ToNumber(targetAddress) & mask) !== (address & mask)) continue;
      broadcasts.add(numberToIpv4((address | (~mask >>> 0)) >>> 0));
    }
  }
  return [...broadcasts];
}

function sendPacket(packet: Buffer, host: string, port: number) {
  return new Promise<void>((resolve, reject) => {
    const socket = dgram.createSocket('udp4');
    let settled = false;
    const finish = (error?: Error | null) => {
      if (settled) return;
      settled = true;
      socket.removeListener('error', finish);
      try { socket.close(); } catch { /* The socket may fail before binding. */ }
      if (error) reject(error);
      else resolve();
    };
    socket.once('error', finish);
    socket.bind(0, () => {
      socket.setBroadcast(true);
      socket.send(packet, port, host, finish);
    });
  });
}

function ipv4ToNumber(value: string) {
  return value.split('.').reduce((result, octet) => ((result << 8) | Number(octet)) >>> 0, 0);
}

function numberToIpv4(value: number) {
  return [24, 16, 8, 0].map((shift) => (value >>> shift) & 0xff).join('.');
}

function isIpv4(value: string) {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
}

function delay(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
