import { PanelExtensionContext } from "@foxglove/extension";
import { ParameterDetails, ParameterValueDetails } from "parameter_types";
import { ReactElement, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

import { PanelSettings } from "./panelSettings";

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  console.log("Initializing EditParamPanel component.");

  const [settings, setSettings] = useState<PanelSettings>({} as PanelSettings);

  useEffect(() => {
    console.log("EditParamPanel effect is running.");

    // Tell Foxglove we want to receive parameter updates.
    context.watch("parameters");

    // Set up the render handler. This is called by Foxglove when data changes.
    context.onRender = (renderState, done) => {
      if (renderState.parameters) {
        setSettings((prevSettings: PanelSettings): PanelSettings => {
          // Update the settings with the new parameters
          const updatedSettings: PanelSettings = { ...prevSettings };
          return updatedSettings;
        });
        const params: Map<string, Array<ParameterDetails>> = new Map<
          string,
          Array<ParameterDetails>
        >();
        // Assuming renderState.parameters is a Map<string, any>
        renderState.parameters.forEach((value, name) => {
          const parts = name.split(".");
          if (parts.length < 2) {
            console.warn(
              `Parameter name "${name}" does not have the expected format "node_name.param_name". Skipping this parameter.`,
            );
            return;
          }
          const node_name = parts[0]; // Extract node name from parameter name
          if (!node_name) {
            console.warn(
              `Node name is empty in parameter "${name}". Skipping this parameter.`,
            );
            return;
          }
          const param_name = parts[1]; // Extract parameter name
          if (
            !param_name ||
            param_name.trim() === "" ||
            typeof param_name !== "string"
          ) {
            console.warn(
              `Parameter name is empty in parameter "${name}". Skipping this parameter.`,
            );
            return;
          }
          // Initialize the array for this node if it doesn't exist
          if (!params.has(node_name)) {
            params.set(node_name, []);
          }
          // Add the parameter details to the node's array
          params.get(node_name)?.push({
            name: param_name,
            value: value as ParameterValueDetails, // Cast to the expected type
          });
        });
      } else {
        console.warn(
          "onRender called, but no parameters found in render state.",
        );
      }
      done();
    };

    // CRITICAL STEP: Activate the panel's render loop by subscribing.
    // Even an empty subscription is enough to tell Foxglove that this panel
    // is ready to receive updates for its "watched" properties.
    context.subscribe([]);

    // The cleanup function for when the panel is unmounted.
    return () => {
      // Unsubscribe from all topics when the panel is destroyed.
      context.unsubscribeAll();
    };
  }, [context]);

  return (
    <div>
      <h1>Edit Parameter</h1>
      <p>This panel allows you to edit parameters of a selected node.</p>
      <p>Check the browser console for parameter logs.</p>
    </div>
  );
}

export function initEditParamPanel(context: PanelExtensionContext): () => void {
  const root = createRoot(context.panelElement);
  root.render(<EditParamPanel context={context} />);
  return () => {
    root.unmount();
  };
}
