import { describe, expect, it } from 'vitest';
import { parseArpMac } from '../electron/services/DiscoveryService';

describe('Windows TV adapter discovery', () => {
  it('extracts only the adapter associated with the verified address', () => {
    const output = `
Interface: 192.168.50.110 --- 0x13
  Internet Address      Physical Address      Type
  192.168.50.21          02-22-33-44-55-66     dynamic
  192.168.50.42          02-11-22-33-44-55     dynamic
`;
    expect(parseArpMac(output, '192.168.50.42')).toBe('02:11:22:33:44:55');
    expect(parseArpMac(output, '192.168.50.93')).toBeUndefined();
  });

  it('rejects malformed addresses and multicast results', () => {
    expect(parseArpMac('192.168.50.42 01-00-5e-00-00-fb dynamic', '192.168.50.42')).toBeUndefined();
    expect(parseArpMac('192.168.50.42 02-11-22-33-44-55 dynamic', 'not-an-ip')).toBeUndefined();
  });
});
