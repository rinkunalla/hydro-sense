// Network task: Wi-Fi portal, clock sync, registration, uploads and retries.
// Runs on its own FreeRTOS task so a slow server never stalls sampling.
#pragma once

namespace hs::net {

/** Starts the network task (core 0). */
void start();

}  // namespace hs::net
