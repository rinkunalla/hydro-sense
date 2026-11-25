import "./globalOptions";

export { registerDevice } from "./device/registerDevice";
export { deviceIngest } from "./device/deviceIngest";
export { monitorDevices } from "./monitor/monitorDevices";
export { calibrateFlowThresholdsWeekly } from "./calibration/calibrate";
export {
  adminListStaff,
  createStaff,
  updateStaff,
  resetStaffPassword,
  deleteStaff,
} from "./admin/staff";
export { addAllowedDevice, updateDevice, removeDevice } from "./admin/devices";
export {
  requestAdminSetup,
  completeAdminSetup,
  removeAdmin,
  listAdmins,
  updateMyAdminName,
  updateMyAdminMobile,
  syncMyAdmin,
  signOutEverywhere,
} from "./admin/admins";
export { placeSuggest, placeLocation } from "./maps/places";
export { claimPushToken } from "./alerts/pushTokens";
