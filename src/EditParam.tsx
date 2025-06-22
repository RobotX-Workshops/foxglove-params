import { PanelExtensionContext } from "@foxglove/extension";
import { ParameterDetails, ParameterValueDetails } from "parameter_types";
import { ReactElement, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

import { NumericSettings, PanelSettings } from "./panelSettings";

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

  if (!settings.selectedNode) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Please select a node to view and edit its parameters. The available
          nodes will be populated once the WebSocket connection is established.
        </p>
      </div>
    );
  }

  if (!settings.selectedParameterName) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Please select a parameter from the settings panel to edit its value.
        </p>
      </div>
    );
  }

  // --- RENDER LOGIC WITH `context.setParameter` ---

  const nodeParams = settings.params.get(settings.selectedNode) ?? [];

  if (!Array.isArray(nodeParams) || nodeParams.length === 0) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          No parameters found for the selected node: {settings.selectedNode}
        </p>
      </div>
    );
  }

  const fullParamName = `${settings.selectedNode}.${settings.selectedParameterName}`;

  const selectedParam = nodeParams.find(
    (param) => param.name === settings.selectedParameterName,
  );

  if (!selectedParam) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Parameter &quot;{settings.selectedParameterName}&quot; not found for
          {settings.selectedNode}.
        </p>
      </div>
    );
  }

  if (settings.inputType === "number") {
    const numberSettings = settings as NumericSettings;

    const numVal = Number(selectedParam.value);

    return (
      <div
        style={{
          display: "flex",
          flexDirection: "row",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <input
          type="number"
          min={numberSettings.min}
          max={numberSettings.max}
          step={numberSettings.step}
          value={numVal}
          onChange={(e) => {
            const value = parseFloat(e.target.value);
            console.log(
              `Setting parameter ${fullParamName} to ${value} via context.setParameter`,
            );
            context.setParameter(fullParamName, value);
          }}
          style={{ padding: "0.3rem", margin: "0.3rem" }}
        />
      </div>
    );
  }
  if (settings.inputType === "slider") {
    const numVal = Number(selectedParam.value);
    if (isNaN(numVal)) {
      console.warn(
        `Expected number value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid number value</div>;
    }
    const sliderSettings = settings as NumericSettings;
    return (
      <div
        style={{
          display: "flex",
          flexDirection: "row",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <input
          type="range"
          min={sliderSettings.min}
          max={sliderSettings.max}
          step={sliderSettings.step}
          value={numVal}
          onChange={(e) => {
            const value = parseFloat(e.target.value);

            context.setParameter(fullParamName, value);
          }}
          style={{ padding: "1rem", flexGrow: 1 }}
        />
        <div>{numVal.toFixed(2)}</div>
      </div>
    );
  }
  if (settings.inputType === "boolean") {
    if (typeof selectedParam.value !== "boolean") {
      console.warn(
        `Expected boolean value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid boolean value</div>;
    }
    return (
      <input
        type="checkbox"
        checked={selectedParam.value}
        onChange={(e) => {
          const value = e.target.checked;
          context.setParameter(fullParamName, value);
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (settings.inputType === "text") {
    if (typeof selectedParam.value !== "string") {
      console.warn(
        `Expected string value for parameter ${fullParamName}, but got: ${String(selectedParam.value)}`,
      );
      return <div>Invalid text value</div>;
    }
    return (
      <input
        type="text"
        value={selectedParam.value}
        onChange={(e) => {
          const value = e.target.value;
          // Use context.setParameter instead of callService
          context.setParameter(fullParamName, value);
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  return <div>Unknown input type</div>;
}

export function initEditParamPanel(context: PanelExtensionContext): () => void {
  const root = createRoot(context.panelElement);
  root.render(<EditParamPanel context={context} />);
  return () => {
    root.unmount();
  };
}
