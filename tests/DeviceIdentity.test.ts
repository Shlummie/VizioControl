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
    const backyard: DeviceCandidate = {
      id: 'backyard-id',
      name: 'Backyard',
      address: '192.168.50.114',
      model: 'D32h-G9',
      serial: '44LINIXZUW08726',
      fingerprint: paired.fingerprint,
      macAddress: '02:66:77:88:99:AA',
      source: 'mdns',
    };

    expect(isSameDevice(paired, backyard)).toBe(false);
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
      id: 'c8599ce74c872bfd',
      address: '192.168.50.114',
      model: 'D32h-G9',
      serial: '44LINIXZUW08726',
      macAddress: '02:66:77:88:99:AA',
    };
    const tv: DeviceCandidate = {
      id: 'c8599ce74c872bfd',
      name: 'LIVING ROOM TV',
      address: '192.168.50.42',
      model: 'TEST-MODEL',
      serial: '14LINID4PZ06139',
      fingerprint: corrupted.fingerprint,
      macAddress: '02:11:22:33:44:55',
      source: 'mdns',
    };
    const backyard: DeviceCandidate = {
      id: 'bb2d24b4a982bf02',
      name: 'Backyard',
      address: '192.168.50.114',
      model: 'D32h-G9',
      serial: '44LINIXZUW08726',
      fingerprint: corrupted.fingerprint,
      macAddress: '02:66:77:88:99:AA',
      source: 'cached',
    };

    expect(isSameDevice(corrupted, backyard)).toBe(false);
    expect(isSameDevice(corrupted, tv)).toBe(true);
  });
});
