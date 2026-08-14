import { CodexAppServerService } from '../electron/services/CodexAppServerService';

const userDataPath = process.argv[2];
if (!userDataPath) throw new Error('Pass the VizioControl user-data directory.');

void main();

async function main() {
  const service = new CodexAppServerService(userDataPath);
  try {
    const state = await service.getState();
    console.log(JSON.stringify({
      status: state.status,
      signedIn: state.signedIn,
      ready: state.ready,
      planType: state.planType,
      model: state.model,
      effort: state.effort,
      runtimeVersion: state.runtimeVersion,
      usage: state.usage,
      error: state.error,
    }, null, 2));
    if (!state.ready) process.exitCode = 2;
  } finally {
    await service.shutdown();
  }
}
