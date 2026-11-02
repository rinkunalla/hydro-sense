import { setGlobalOptions } from "firebase-functions";
import { MAX_INSTANCES, REGION } from "./config";

setGlobalOptions({ region: REGION, maxInstances: MAX_INSTANCES });

// Functions are added phase by phase (KICKOFF.md).
