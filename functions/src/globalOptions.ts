import { setGlobalOptions } from "firebase-functions";
import { MAX_INSTANCES, REGION } from "./config";

// Imported first by index.ts so every function definition sees these options.
setGlobalOptions({ region: REGION, maxInstances: MAX_INSTANCES });
