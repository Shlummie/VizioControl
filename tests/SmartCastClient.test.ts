import { describe, expect, it, vi } from 'vitest';
import {
  KEY_CODES,
  appNameFromIdentity,
  flatVolumePayload,
  keyPayload,
  keySequencePayload,
  pairingFinishPayload,
  pairingStartPayload,
  parseDeviceInfo,
  textPayload,
  volumePayload,
  SmartCastClient,
  settingPayload,
} from '../electron/services/SmartCastClient';

describe('SmartCast protocol payloads', () => {
  it('names verified built-in app identities even when the TV omits a name and URL', () => {
    expect(appNameFromIdentity('3', 2)).toBe('Hulu');
    expect(appNameFromIdentity('1', 3)).toBe('Netflix');
    expect(appNameFromIdentity('1', 4)).toBe('Prime Video');
    expect(appNameFromIdentity('1', 5)).toBe('YouTube');
    expect(appNameFromIdentity('9', 9)).toBe('');
  });

  it('uses the verified Vizio key codes', () => {
    expect(KEY_CODES.ok).toEqual({ codeset: 3, code: 2 });
    expect(KEY_CODES.mute).toEqual({ codeset: 5, code: 4 });
    expect(keyPayload('home')).toEqual({
      KEYLIST: [{ CODESET: 4, CODE: 3, ACTION: 'KEYPRESS' }],
    });
    expect(keyPayload('down', 2)).toEqual({
      KEYLIST: [
        { CODESET: 3, CODE: 0, ACTION: 'KEYPRESS' },
        { CODESET: 3, CODE: 0, ACTION: 'KEYPRESS' },
      ],
    });
    expect(keySequencePayload(['right', 'down', 'ok'])).toEqual({
      KEYLIST: [
        { CODESET: 3, CODE: 7, ACTION: 'KEYPRESS' },
        { CODESET: 3, CODE: 0, ACTION: 'KEYPRESS' },
        { CODESET: 3, CODE: 2, ACTION: 'KEYPRESS' },
      ],
    });
  });

  it('builds bounded direct-volume and text-entry payloads', () => {
    expect(volumePayload(4168459545, 101)).toEqual({
      REQUEST: 'MODIFY', HASHVAL: 4168459545, VALUE: 100,
    });
    expect(flatVolumePayload(101)).toEqual({ LEVEL: 100 });
    expect(textPayload('Hi')).toEqual({
      KEYLIST: [
        { CODESET: 0, CODE: 72, ACTION: 'KEYPRESS' },
        { CODESET: 0, CODE: 105, ACTION: 'KEYPRESS' },
      ],
    });
    expect(settingPayload(3984542095, 60)).toEqual({
      REQUEST: 'MODIFY', HASHVAL: 3984542095, VALUE: 60,
    });
    expect(settingPayload(3878194901, '60 minutes')).toEqual({
      REQUEST: 'MODIFY', HASHVAL: 3878194901, VALUE: '60 minutes',
    });
  });

  it('builds pairing payloads without placing an auth token in them', () => {
    expect(pairingStartPayload('device-1')).toEqual({ DEVICE_ID: 'device-1', DEVICE_NAME: 'VizioControl' });
    expect(pairingFinishPayload('device-1', 42, '1234')).toEqual({
      DEVICE_ID: 'device-1', CHALLENGE_TYPE: 1, RESPONSE_VALUE: '1234', PAIRING_REQ_TOKEN: 42,
    });
  });

  it('extracts identity from nested CNAME records used by SmartCast', () => {
    expect(parseDeviceInfo({
      ITEMS: [{
        CNAME: 'deviceInfo',
        ITEMS: [
          { CNAME: 'modelName', VALUE: 'TEST-MODEL' },
          { CNAME: 'serialNumber', VALUE: 'SERIAL-1' },
          { CNAME: 'deviceinfo', VALUE: { CAST_NAME: 'TV' } },
        ],
      }],
    })).toEqual({ model: 'TEST-MODEL', serial: 'SERIAL-1', name: 'TV' });
  });

  it('reads power from the ITEMS response shape used by TV firmware', async () => {
    const client = new SmartCastClient('192.168.50.42');
    vi.spyOn(client, 'request').mockResolvedValue({
      ITEMS: [{ NAME: 'Power Mode', CNAME: 'power_mode', VALUE: 1 }],
    });

    await expect(client.getPower()).resolves.toBe(true);
  });

  it('uses TV firmware single-request volume endpoint', async () => {
    const client = new SmartCastClient('192.168.50.42');
    const request = vi.spyOn(client, 'request').mockResolvedValue({ STATUS: { RESULT: 'SUCCESS' } });

    await client.setVolume(37);

    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith('/audio/volume/level', 'PUT', { LEVEL: 37 });
  });

  it('batches repeated key presses into one sequential KEYLIST request', async () => {
    const client = new SmartCastClient('192.168.50.42');
    client.setToken('test-token');
    const request = vi.spyOn(client, 'request').mockResolvedValue({ STATUS: { RESULT: 'SUCCESS' } });

    await client.pressKey('down', 2);

    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith('/key_command/', 'PUT', {
      KEYLIST: [
        { CODESET: 3, CODE: 0, ACTION: 'KEYPRESS' },
        { CODESET: 3, CODE: 0, ACTION: 'KEYPRESS' },
      ],
    }, true, 8000);
  });

  it('coalesces rapid ordered controls waiting behind an in-flight TV response', async () => {
    const client = new SmartCastClient('192.168.50.42');
    client.setToken('test-token');
    const first = deferred<{ STATUS: { RESULT: string } }>();
    const request = vi.spyOn(client, 'request')
      .mockImplementationOnce(() => first.promise)
      .mockResolvedValue({ STATUS: { RESULT: 'SUCCESS' } });

    const right = client.pressKey('right');
    const down = client.pressKey('down');
    const left = client.pressKey('left');
    const ok = client.pressKey('ok');
    expect(request).toHaveBeenCalledOnce();

    first.resolve({ STATUS: { RESULT: 'SUCCESS' } });
    await Promise.all([right, down, left, ok]);

    expect(request).toHaveBeenCalledTimes(2);
    expect(request).toHaveBeenNthCalledWith(2, '/key_command/', 'PUT', keySequencePayload(['down', 'left', 'ok']), true, 8000);
  });

  it('keeps power commands as standalone ordering barriers', async () => {
    const client = new SmartCastClient('192.168.50.42');
    client.setToken('test-token');
    const first = deferred<{ STATUS: { RESULT: string } }>();
    const request = vi.spyOn(client, 'request')
      .mockImplementationOnce(() => first.promise)
      .mockResolvedValue({ STATUS: { RESULT: 'SUCCESS' } });

    const right = client.pressKey('right');
    const power = client.pressKey('powerOff');
    const left = client.pressKey('left');
    first.resolve({ STATUS: { RESULT: 'SUCCESS' } });
    await Promise.all([right, power, left]);

    expect(request).toHaveBeenCalledTimes(3);
    expect(request).toHaveBeenNthCalledWith(2, '/key_command/', 'PUT', keyPayload('powerOff'), true, 8000);
    expect(request).toHaveBeenNthCalledWith(3, '/key_command/', 'PUT', keyPayload('left'), true, 8000);
  });

  it('sends only the newest slider value waiting behind an in-flight update', async () => {
    const client = new SmartCastClient('192.168.50.42');
    const first = deferred<{ STATUS: { RESULT: string } }>();
    const request = vi.spyOn(client, 'request')
      .mockImplementationOnce(() => first.promise)
      .mockResolvedValue({ STATUS: { RESULT: 'SUCCESS' } });

    const volume20 = client.setVolume(20);
    const volume35 = client.setVolume(35);
    const volume48 = client.setVolume(48);
    expect(request).toHaveBeenCalledOnce();

    first.resolve({ STATUS: { RESULT: 'SUCCESS' } });
    await Promise.all([volume20, volume35, volume48]);

    expect(request).toHaveBeenCalledTimes(2);
    expect(request).toHaveBeenNthCalledWith(1, '/audio/volume/level', 'PUT', { LEVEL: 20 });
    expect(request).toHaveBeenNthCalledWith(2, '/audio/volume/level', 'PUT', { LEVEL: 48 });
  });

  it('leaves an already configured Quick Start power mode unchanged', async () => {
    const client = new SmartCastClient('192.168.50.42');
    const request = vi.spyOn(client, 'request').mockResolvedValue({
      ITEMS: [{ CNAME: 'power_mode', VALUE: 'Quick Start', HASHVAL: 9001, ELEMENTS: ['Eco Mode', 'Quick Start'] }],
    });

    await expect(client.ensureQuickStartPowerMode()).resolves.toEqual({ changed: false, value: 'Quick Start' });
    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith('/menu_native/dynamic/tv_settings/system', 'GET');
  });

  it('switches Eco Mode to Quick Start and verifies it before power-off can continue', async () => {
    const client = new SmartCastClient('192.168.50.42');
    const request = vi.spyOn(client, 'request')
      .mockResolvedValueOnce({
        ITEMS: [{ CNAME: 'power_mode', VALUE: 'Eco Mode', HASHVAL: 9002, ELEMENTS: ['Eco Mode', 'Quick Start'] }],
      })
      .mockResolvedValueOnce({ STATUS: { RESULT: 'SUCCESS' } })
      .mockResolvedValueOnce({
        ITEMS: [{ CNAME: 'power_mode', VALUE: 'Quick Start', HASHVAL: 9003, ELEMENTS: ['Eco Mode', 'Quick Start'] }],
      });

    await expect(client.ensureQuickStartPowerMode()).resolves.toEqual({ changed: true, value: 'Quick Start' });
    expect(request).toHaveBeenNthCalledWith(2,
      '/menu_native/dynamic/tv_settings/system/power_mode',
      'PUT',
      { REQUEST: 'MODIFY', HASHVAL: 9002, VALUE: 'Quick Start' },
    );
    expect(request).toHaveBeenNthCalledWith(3, '/menu_native/dynamic/tv_settings/system', 'GET');
  });

  it('fails closed when the TV cannot prove it entered Quick Start mode', async () => {
    const client = new SmartCastClient('192.168.50.42');
    vi.spyOn(client, 'request')
      .mockResolvedValueOnce({ ITEMS: [{ CNAME: 'power_mode', VALUE: 'Eco Mode', HASHVAL: 9004 }] })
      .mockResolvedValueOnce({ STATUS: { RESULT: 'SUCCESS' } })
      .mockResolvedValueOnce({ ITEMS: [{ CNAME: 'power_mode', VALUE: 'Eco Mode', HASHVAL: 9005 }] });

    await expect(client.ensureQuickStartPowerMode()).rejects.toThrow('did not confirm Quick Start');
  });

  it('rejects an unknown or read-only Power Mode rather than guessing', async () => {
    const unknown = new SmartCastClient('192.168.50.42');
    vi.spyOn(unknown, 'request').mockResolvedValue({
      ITEMS: [{ CNAME: 'power_mode', VALUE: 'Custom Mode', HASHVAL: 9006 }],
    });
    await expect(unknown.ensureQuickStartPowerMode()).rejects.toThrow('unrecognized Power Mode');

    const readOnly = new SmartCastClient('192.168.50.42');
    vi.spyOn(readOnly, 'request').mockResolvedValue({
      ITEMS: [{ CNAME: 'power_mode', VALUE: 'Eco Mode', HASHVAL: 9007, READONLY: 'TRUE' }],
    });
    await expect(readOnly.ensureQuickStartPowerMode()).rejects.toThrow('Power Mode is read-only');
  });

  it('writes and verifies an allowlisted numeric TV setting with the current hash', async () => {
    const client = new SmartCastClient('192.168.50.42');
    const request = vi.spyOn(client, 'request')
      .mockResolvedValueOnce({ ITEMS: [{ CNAME: 'backlight', VALUE: 35, HASHVAL: 1001 }] })
      .mockResolvedValueOnce({ STATUS: { RESULT: 'SUCCESS' } })
      .mockResolvedValueOnce({ ITEMS: [{ CNAME: 'backlight', VALUE: 40, HASHVAL: 1002 }] });

    await expect(client.setSetting('screenBrightness', 40)).resolves.toBe(40);
    expect(request).toHaveBeenNthCalledWith(2,
      '/menu_native/dynamic/tv_settings/picture/backlight',
      'PUT',
      { REQUEST: 'MODIFY', HASHVAL: 1001, VALUE: 40 },
    );
  });

  it('restricts sleep timers to values TV actually exposes', async () => {
    const client = new SmartCastClient('192.168.50.42');
    vi.spyOn(client, 'request').mockResolvedValue({
      ITEMS: [{ CNAME: 'sleep_timer', VALUE: 'Off', HASHVAL: 2001 }],
    });

    await expect(client.setSetting('sleepTimer', '45 minutes' as never)).rejects.toThrow('Sleep timer must be');
  });

  it('adjusts brightness relatively and keeps it within the verified range', async () => {
    const client = new SmartCastClient('192.168.50.42');
    vi.spyOn(client, 'readSetting')
      .mockResolvedValueOnce(98)
      .mockResolvedValueOnce(100);
    const request = vi.spyOn(client, 'request')
      .mockResolvedValueOnce({ ITEMS: [{ CNAME: 'backlight', VALUE: 98, HASHVAL: 3001 }] })
      .mockResolvedValueOnce({ STATUS: { RESULT: 'SUCCESS' } });

    await expect(client.adjustSetting('screenBrightness', 5)).resolves.toEqual({ before: 98, value: 100 });
    expect(request).toHaveBeenNthCalledWith(2,
      '/menu_native/dynamic/tv_settings/picture/backlight',
      'PUT',
      { REQUEST: 'MODIFY', HASHVAL: 3001, VALUE: 100 },
    );
  });

  it('rejects a responsive TV whose serial is not the paired TV', async () => {
    const client = new SmartCastClient('192.168.50.114');
    client.configure({
      id: 'tv-id',
      name: 'TV',
      address: '192.168.50.114',
      serial: 'SERIAL-1',
      deviceId: 'client-id',
      pairedAt: '2026-08-13T00:00:00.000Z',
    }, null);
    vi.spyOn(client, 'getDeviceInfo').mockResolvedValue({
      ITEMS: [{ VALUE: { MODEL_NAME: 'TEST-MODEL-2', SYSTEM_INFO: { SERIAL_NUMBER: 'SERIAL-2' } } }],
    });
    const power = vi.spyOn(client, 'getPower');

    await expect(client.getState()).resolves.toMatchObject({
      connected: false,
      error: 'The TV at this address is not the paired TV. Rediscovering the verified TV.',
    });
    expect(power).not.toHaveBeenCalled();
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}
