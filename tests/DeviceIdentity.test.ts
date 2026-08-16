import { describe, expect, it } from 'vitest';
import { isSameDevice } from '../electron/services/RemoteController';
import type { DeviceCandidate, PairedDevice } from '../src/shared/types';

const paired: PairedDevice = {
  id: 'old-id', name: 'TV', address: '192.168.50.42', serial: 'SERIAL-1', fingerprint: 'AA:BB',
  macAddress: '02:11:22:33:44:55',
  deviceId: 'client-id', pairedAt: '2026-08-13T00:00:00.000Z',
};

describe('DHCP identity matching', () => {
  it('recognizes TV after an address change without trusting the address', () => {
    const moved: DeviceCandidate = {
      id: 'new-id', name: 'TV', address: '192.168.50.123', serial: 'SERIAL-1', fingerprint: 'AA:BB', source: 'mdns',
    };
    expect(isSameDevice(paired, moved)).toBe(true);
  });

  it('does not accept an unrelated device at the cached address', () => {
    const unrelated: DeviceCandidate = {
      id: 'different', name: 'Other TV', address: paired.address, serial: 'SERIAL-2', fingerprint: 'CC:DD', source: 'cached',
    };
    expect(isSameDevice(paired, unrelated)).toBe(false);
  });

  it('rejects a different Vizio that reuses TV\'s TLS certificate', () => {
    const secondary: DeviceCandidate = {
      id: 'secondary-id',
      name: 'Secondary TV',
      address: '192.168.50.114',
      model: 'TEST-MODEL-2',
      serial: 'SERIAL-2',
      fingerprint: paired.fingerprint,
      macAddress: '02:66:77:88:99:AA',
      source: 'mdns',
    };

    expect(isSameDevice(paired, secondary)).toBe(false);
  });

  it('uses the verified MAC when a legacy candidate has no serial', () => {
    const moved: DeviceCandidate = {
      id: 'legacy-id',
      name: 'TV',
      address: '192.168.50.123',
      macAddress: '02-11-22-33-44-55',
      source: 'mdns',
    };

    expect(isSameDevice({ ...paired, serial: undefined }, moved)).toBe(true);
  });

  it('recovers a record whose serial was overwritten by a shared-certificate TV', () => {
    const corrupted: PairedDevice = {
      ...paired,
      id: '1111222233334444',
      address: '192.168.50.114',
      model: 'TEST-MODEL-2',
      serial: 'SERIAL-2',
      macAddress: '02:66:77:88:99:AA',
    };
    const tv: DeviceCandidate = {
      id: '1111222233334444',
      name: 'TV',
      address: '192.168.50.42',
      model: 'TEST-MODEL',
      serial: 'SERIAL-1',
      fingerprint: corrupted.fingerprint,
      macAddress: '02:11:22:33:44:55',
      source: 'mdns',
    };
    const secondary: DeviceCandidate = {
      id: 'aaaabbbbccccdddd',
      name: 'Secondary TV',
      address: '192.168.50.114',
      model: 'TEST-MODEL-2',
      serial: 'SERIAL-2',
      fingerprint: corrupted.fingerprint,
      macAddress: '02:66:77:88:99:AA',
      source: 'cached',
    };

    expect(isSameDevice(corrupted, secondary)).toBe(false);
    expect(isSameDevice(corrupted, tv)).toBe(true);
  });
});
