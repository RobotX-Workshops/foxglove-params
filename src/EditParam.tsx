import { PanelExtensionContext } from "@foxglove/extension";
import { ReactElement, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

import { buildSettingsTree, settingsActionReducer } from "./panelSettings";
import {
  NumericSettings,
  PanelSettings,
  PanelState,
  ParameterDetails,
  ParameterValueDetails,
  Settings,
} from "./types";
import { parseParameters } from "./utils/mappers";

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  console.log("Initializing EditParamPanel component.");

  const updateTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  const [settings, setSettings] = useState<PanelSettings>(() => {
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

  // Debounced parameter update function
  const updateParameterWithDelay = (
    paramName: string,
    value: number | string | boolean,
  ) => {
    if (updateTimeoutRef.current) {
      clearTimeout(updateTimeoutRef.current);
    }

    updateTimeoutRef.current = setTimeout(() => {
      console.log(
        `Setting parameter ${paramName} to ${String(value)} via context.setParameter`,
      );
      context.setParameter(paramName, value);
    }, 150); // 150ms delay to prevent overwhelming the system
  };

  useEffect(() => {
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
            params: new Map(params as Iterable<[string, ParameterDetails[]]>),
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
    context.saveState({ settings });
  }, [settings, context]);

  useEffect(() => {
    context.updatePanelSettingsEditor({
      actionHandler: (action) => {
        setSettings((prevSettings) =>
          settingsActionReducer(prevSettings, action),
        );
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
  // Check that the .get method exists on the params Map
  if (
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition, @typescript-eslint/strict-boolean-expressions
    !settings.params ||
    settings.params.size === 0 ||
    typeof settings.params.get !== "function"
  ) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>No parameters available for the selected node.</p>
      </div>
    );
  }

  const nodeParams: Array<ParameterDetails> =
    settings.params.get(settings.selectedNode) ?? [];

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

  if (selectedParam == undefined) {
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
            updateParameterWithDelay(fullParamName, value);
          }}
          style={{
            padding: "0.3rem",
            margin: "0.3rem",
            width: "80%",
            minWidth: "60px",
          }}
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
          padding: "1rem",
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

            updateParameterWithDelay(fullParamName, value);
          }}
          style={{ padding: "1rem", width: "calc(80% - 40px)" }}
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
      <div
        style={{
          display: "flex",
          flexDirection: "row",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <input
          type="checkbox"
          checked={selectedParam.value}
          onChange={(e) => {
            const value = e.target.checked;
            updateParameterWithDelay(fullParamName, value);
          }}
          style={{
            padding: "1rem",
          }}
        />
      </div>
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
