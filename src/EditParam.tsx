import { PanelExtensionContext } from "@foxglove/extension";
import { ParameterValueDetails } from "parameter_types";
import { ReactElement, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

import {
  NumericSettings,
  PanelSettings,
  Settings,
  buildSettingsTree,
  settingsActionReducer,
} from "./panelSettings";
import { parseParameters } from "./utils/mappers";

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  console.log("Initializing EditParamPanel component.");

  const [settings, setSettings] = useState<PanelSettings>(() => {
    // State initialization is unchanged
    const initialState = context.initialState as
      | Partial<PanelState>
      | undefined;
    if (initialState?.settings == undefined) {
      console.warn(
        "No initial state found, using default settings for EditParamPanel",
      );
      return {
        selectedNode: "",
        selectedParameterName: "",
        params: new Map<
          string,
          Array<{ name: string; value: ParameterValueDetails }>
        >(),
        inputType: "number",
      } as Settings;
    }

    const partialSettings = initialState.settings as
      | Partial<PanelSettings>
      | undefined;

    return {
      selectedNode: partialSettings?.selectedNode ?? "",
      selectedParameterName: partialSettings?.selectedParameterName ?? "",
      inputType: partialSettings?.inputType ?? "number",
      params:
        partialSettings?.params ??
        new Map<
          string,
          Array<{ name: string; value: ParameterValueDetails }>
        >(),
    };
  });

  useEffect(() => {
    console.log("EditParamPanel effect is running.");

    // Tell Foxglove we want to receive parameter updates.
    context.watch("parameters");

    // Set up the render handler. This is called by Foxglove when data changes.
    context.onRender = (renderState, done) => {
      if (renderState.parameters) {
        const incomingParameters = renderState.parameters;

        const params = parseParameters(incomingParameters);

        setSettings((prevSettings: PanelSettings): PanelSettings => {
          const updatedSettings: PanelSettings = {
            ...prevSettings,
            params: new Map(params),
          };
          // Update the parameters for this node
          return updatedSettings;
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

  useEffect(() => {
    context.updatePanelSettingsEditor({
      actionHandler: (action) => {
        setSettings((prevSettings) => {
          if (action.action === "update") {
            const path = action.payload.path;
            const value = action.payload.value;

            // Check if the path to the changed setting matches what you expect.
            // The path is an array of strings representing the keys in your settings tree. [3]
            // For a path of, your SettingsTree nodes would
            // be structured like: { nodes: { dataSource: { fields: { inputType:... } } } }
            const isInputTypePath =
              path.length === 2 &&
              path[0] === "dataSource" &&
              path[1] === "inputType";

            if (isInputTypePath) {
              // Finally, check if the new value is "number".
              if (value === "number") {
                console.log('Input type was set to "number".');
                const prevSet = prevSettings as any;
                if (!prevSet.min) {
                  console.warn(
                    "No min value set for numeric input type. Defaulting to 0.",
                  );
                }
                if (!prevSet.max) {
                  console.warn(
                    "No max value set for numeric input type. Defaulting to 100.",
                  );
                }
                setSettings((prevSett) => {
                  // Ensure we return a new object with the updated properties.
                  // This is important for React to detect changes.
                  return {
                    ...prevSett,
                    inputType: "number",
                    min: prevSet.min ?? -100,
                    max: prevSet.max ?? 100,
                    step: prevSet.step ?? 0.1,
                  };
                });
              }
            }
          }
          return settingsActionReducer(prevSettings, action);
        });
      },
      nodes: buildSettingsTree(settings),
    });
  }, [settings, context]);

  if (!settings.selectedNode) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Please select a node in the settings panel to view and edit its
          parameters. The available nodes will be populated once the WebSocket
          connection is established.
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
