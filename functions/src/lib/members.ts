// /members/{uid} in the Realtime Database: true while a staff member or
// admin is active. The live channel's rules read it (D62), so disabling or
// deleting an account ends its live access at once, before its ID token expires.
import { memberRef } from "./db";

export async function setMember(uid: string, active: boolean): Promise<void> {
  await (active ? memberRef(uid).set(true) : memberRef(uid).remove());
}
