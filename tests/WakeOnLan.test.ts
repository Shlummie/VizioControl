import { describe, expect, it } from 'vitest';
import { buildMagicPacket, localBroadcastAddresses, normalizeMacAddress } from '../electron/services/WakeOnLanService';

describe('TV wake packets', () => {
  it('normalizes a unicast adapter address and rejects unsafe values', () => {
    expect(normalizeMacAddress('02-11-22-33-44-55')).toBe('02:11:22:33:44:55');
    expect(normalizeMacAddress('ff:ff:ff:ff:ff:ff')).toBeUndefined();
    expect(normalizeMacAddress('01:00:5e:00:00:fb')).toBeUndefined();
    expect(normalizeMacAddress('not-a-mac')).toBeUndefined();
  });

  it('builds the standard six-byte prefix plus sixteen MAC repetitions', () => {
    const packet = buildMagicPacket('02:11:22:33:44:55');
    expect(packet).toHaveLength(102);
    expect(packet.subarray(0, 6)).toEqual(Buffer.alloc(6, 0xff));
    for (let offset = 6; offset < packet.length; offset += 6) {
      expect(packet.subarray(offset, offset + 6).toString('hex')).toBe('021122334455');
    }
  });

  it('derives LAN broadcast addresses without using VPN or loopback adapters', () => {
    const interfaces = {
      Ethernet: [{ address: '192.168.50.110', netmask: '255.255.255.0', family: 'IPv4', mac: '00:00:00:00:00:01', internal: false, cidr: '192.168.50.110/24' }],
      Loopback: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal: true, cidr: '127.0.0.1/8' }],
    };
    expect(localBroadcastAddresses(interfaces as never, '192.168.50.42')).toEqual(['192.168.50.255']);
  });
});
