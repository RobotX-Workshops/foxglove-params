import { ExtensionContext } from "@foxglove/extension";

import { initEditParamPanel } from "./EditParam";

export function activate(extensionContext: ExtensionContext): void {
  extensionContext.registerPanel({
    name: "Parameter Editor",
    initPanel: initEditParamPanel,
  });
}
