import { registerProtocol } from "@wormhole-foundation/sdk-definitions";
import { _platform } from "@wormhole-foundation/sdk-sui";
import { SuiNtt } from "./ntt.js";
import { SuiNttWithExecutor } from "./nttWithExecutor.js";
import "@wormhole-foundation/sdk-definitions-ntt";

// Register standard protocols
registerProtocol(_platform, "Ntt", SuiNtt);
registerProtocol(_platform, "NttWithExecutor", SuiNttWithExecutor);
// Note: MTokenNtt extends SuiNtt so uses the same registration

export * from "./ntt.js";
export * from "./nttWithExecutor.js";
export * from "./mTokenNtt.js";
export * from "./utils.js";
export * from "./constants.js";
export * from "./bcsTypes.js";