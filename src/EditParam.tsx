import { PanelExtensionContext, SettingsTreeAction } from "@foxglove/extension";
import { ParameterDetails, ParameterValueDetails } from "parameter_types";
import {
  ReactElement,
  useEffect,
  useLayoutEffect,
  useState,
  useCallback,
  useRef,
} from "react";
import { createRoot } from "react-dom/client";

import {
  NumericSettings,
  PanelSettings,
  Settings,
  buildSettingsTree,
  settingsActionReducer,
} from "./panelSettings";
// The mapParamValue function is no longer needed as context.setParameter handles typing.
// import { mapParamValue } from "./utils/mappers";

type FormState = {
  currentEditingValue: string | number | boolean | null;
};
type PanelState = {
  settings: Partial<Settings> | undefined;
};

// Helper to parse the raw parameter data string (replaces extractNodeNames from example)
function extractNodeNames(data: string): string[] {
  if (!data) {
    return [];
  }
  try {
    // Explicitly type the expected structure from JSON.parse
    const parsed: { parameters?: { name: string }[] } = JSON.parse(data);

    if (!parsed.parameters || !Array.isArray(parsed.parameters)) {
      return [];
    }

    // Safely extract node names
    const nodeNames = new Set(
      parsed.parameters
        .map((p) => p.name.split(".")[0])
        .filter((namePart): namePart is string => !!namePart),
    );
    console.log("Extracted node names:", nodeNames);
    return Array.from(nodeNames);
  } catch (e) {
    console.error("Failed to parse parameter data:", e);
    return [];
  }
}

// Helper to parse parameters for a specific node (replaces extractParametersByNode)
function extractParametersForNode(
  data: string,
  nodeName: string,
): ParameterDetails[] {
  if (!data || !nodeName) {
    return [];
  }
  try {
    const parsed = JSON.parse(data);
    if (!parsed.parameters || !Array.isArray(parsed.parameters)) {
      return [];
    }

    const nodeParams: ParameterDetails[] = [];
    parsed.parameters.forEach(
      (param: { name: string; value: ParameterValueDetails }) => {
        const paramName = param.name;
        const nodePrefix = `${nodeName}.`;
        const paramNameWithoutNode = param.name.replace(nodePrefix, "");
        const value = param.value;
        if (paramName.startsWith(nodePrefix)) {
          nodeParams.push({
            name: paramNameWithoutNode,
            value,
          });
        }
      },
    );
    console.log(`Extracted parameters for node ${nodeName}:`, nodeParams);
    return nodeParams;
  } catch (e) {
    console.error("Failed to extract parameters for node:", e);
    return [];
  }
}

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  const [settings, setSettings] = useState<PanelSettings>(() => {
    // State initialization is unchanged
    const initialState = context.initialState as PanelState;
    const partialSettings = initialState.settings ?? {};
    if (partialSettings === undefined) {
      console.warn(
        "No initial settings found, using default settings for EditParamPanel",
      );
      return {
        selectedNode: "",
        availableNodeNames: [],
        selectedParameterName: "",
        selectedNodeAvailableParams: [],
        allData: {},
        inputType: "number",
        min: -100,
        max: 100,
        step: 0.1,
      };
    }
    if (
      partialSettings.inputType === "number" ||
      partialSettings.inputType === "slider"
    ) {
      const numberSettings = partialSettings as NumericSettings;
      console.log(
        "Initializing EditParamPanel with numeric settings",
        numberSettings,
      );
      return {
        selectedNode: partialSettings.selectedNode ?? "",
        availableNodeNames: partialSettings.availableNodeNames ?? [],
        selectedParameterName: partialSettings.selectedParameterName ?? "",
        selectedNodeAvailableParams:
          partialSettings.selectedNodeAvailableParams ?? [],
        allData: partialSettings.allData ?? {},
        inputType: partialSettings.inputType,
        min: numberSettings.min ?? 0,
        max: numberSettings.max ?? 100,
        step: numberSettings.step ?? 1,
      };
    }
    // For non-numeric types, still provide allData and dummy numeric fields to satisfy PanelSettings
    console.log(
      "Initializing EditParamPanel with non-numeric settings",
      partialSettings,
    );
    return {
      selectedNode: partialSettings.selectedNode ?? "",
      availableNodeNames: partialSettings.availableNodeNames ?? [],
      selectedParameterName: partialSettings.selectedParameterName ?? "",
      selectedNodeAvailableParams:
        partialSettings.selectedNodeAvailableParams ?? [],
      allData: partialSettings.allData ?? {},
      inputType: partialSettings.inputType ?? "number",
      min: 0,
      max: 100,
      step: 1,
    };
  });

  // --- Start of new WebSocket logic from example ---
  const [ws, setWs] = useState<WebSocket | null>(null);

  const isInitialMount = useRef(true);

  useEffect(() => {
    // Using the direct WebSocket connection from your example
    const websocket = new WebSocket("ws://localhost:8765", [
      "foxglove.websocket.v1",
    ]);

    websocket.onopen = () => {
      console.log("WebSocket connection established");
      setWs(websocket);
    };
    websocket.onerror = (error) => {
      console.error("WebSocket error:", error);
    };
    websocket.onclose = () => {
      console.log("WebSocket connection closed");
    };
    websocket.onmessage = async (event) => {
      // console.log("Received WebSocket message of type:", typeof event.data);

      // Check if the data is a Blob and needs to be read
      if (event.data instanceof Blob) {
        // console.debug("Received Blob data from WebSocket");
      }
      // Check if it's already a string
      else if (typeof event.data === "string") {

        const nodeNames = extractNodeNames(event.data);
        const allParams = nodeNames.reduce<Record<string, ParameterDetails[]>>(
          (acc, nodeName) => {
            acc[nodeName] = extractParametersForNode(
              event.data as string,
              nodeName,
            );
            return acc;
          },
          {},
        );
        console.log("Received and Extracted node names:", nodeNames);
        setSettings((prev) => ({
          ...prev,
          availableNodeNames: Object.keys(allParams),
          allData: allParams,
        }));
      }
      // Handle other unexpected types
      else {
        console.error(
          "Received non-string/non-blob data from WebSocket:",
          event.data,
        );
        return;
      }
    };
    // No need to setWs(websocket) here as onopen handles it.
    return () => {
      if (websocket.readyState === WebSocket.OPEN) {
        websocket.close();
      }
    };
  }, []); // Empty dependency array ensures this runs only once on mount

  const fetchParameters = useCallback(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      console.log("Requesting parameters from WebSocket...");
      ws.send(
        JSON.stringify({
          op: "getParameters",
          parameterNames: [], // Request all parameters
          id: "fetch-all-parameters",
        }),
      );
    } else {
      console.error("Cannot fetch parameters, WebSocket is not open.");
    }
  }, [ws]);
  // --- End of new WebSocket logic ---

  const [formState, setFormState] = useState<FormState>({
    currentEditingValue: null,
  });

  const settingsActionHandler = useCallback((action: SettingsTreeAction) => {
    setSettings((prevConfig) => settingsActionReducer(prevConfig, action));
  }, []);

  useEffect(() => {
    // Check the ref. If it's the initial mount, we do nothing but flip the flag for next time.
    // We want the component to render with whatever value is loaded from the saved state.
    if (isInitialMount.current) {
      isInitialMount.current = false;
    } else {
      // If it's NOT the initial mount, it means the user has actively selected a new
      // parameter. NOW it's correct to reset the form's editing state.
      setFormState({ currentEditingValue: null });
    }
  }, [settings.selectedParameterName]);

  useEffect(() => {
    context.updatePanelSettingsEditor({
      actionHandler: settingsActionHandler,
      nodes: buildSettingsTree(settings),
    });
    console.debug("Updated panel settings editor with new settings", settings);
    context.saveState({ settings });
  }, [settings, context, settingsActionHandler]);

  // This effect reacts to a node being selected or new data arriving
  useEffect(() => {
    if (!settings.selectedNode) {
      return;
    }

    const paramsForNode = settings.allData[settings.selectedNode] ?? [];

    let selectedParameterName = "";
    if (paramsForNode.some((p) => p.name === settings.selectedParameterName)) {
      selectedParameterName = settings.selectedParameterName;
    }

    // When the node changes, we must update the available parameters
    // AND reset the selected parameter to maintain a consistent state.
    setSettings((prev) => ({
      ...prev,
      selectedNodeAvailableParams: paramsForNode,
      // Reset the selected parameter. Default to the first new parameter or an empty string.
      selectedParameterName,
    }));

    setFormState({ currentEditingValue: null });
  }, [settings.selectedNode, settings.allData, settings.selectedParameterName]);

  useLayoutEffect(() => {
    context.onRender = (_renderState, done) => {
      setRenderDone(() => done);
    };
  }, [context]);

  useEffect(() => {
    renderDone?.();
  }, [renderDone]);

  if (
    !settings.selectedNodeAvailableParams ||
    !settings.selectedParameterName
  ) {
    return (
      <div style={{ padding: "1rem" }}>
        <h2>Parameter Editor</h2>
        <p>
          Click the button to fetch parameters from the robot, then select a
          node and parameter in the panel settings.
        </p>
        <button onClick={fetchParameters} style={{ marginTop: "1rem" }}>
          Fetch Parameters
        </button>
      </div>
    );
  }

  const selectedNodeParamsValue = settings.selectedNodeAvailableParams.find(
    (x) => x.name === settings.selectedParameterName,
  )?.value;

  if (selectedNodeParamsValue == null) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Parameter '{settings.selectedParameterName}' not found for node '
          {settings.selectedNode}'. Try fetching parameters again.
        </p>
        <button onClick={fetchParameters} style={{ marginTop: "1rem" }}>
          Fetch Parameters
        </button>
      </div>
    );
  }

  // --- RENDER LOGIC WITH `context.setParameter` ---

  const fullParamName = `${settings.selectedNode}.${settings.selectedParameterName}`;

  if (settings.inputType === "number") {
    const numberSettings = settings as NumericSettings;
    const numVal = Number(
      formState.currentEditingValue ??
        selectedNodeParamsValue.double_value ??
        selectedNodeParamsValue.integer_value,
    );
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
            // Use context.setParameter instead of callService
            context.setParameter(fullParamName, value);
            setFormState({ currentEditingValue: value });
          }}
          style={{ padding: "0.3rem", margin: "0.3rem" }}
        />
      </div>
    );
  }
  if (settings.inputType === "slider") {
    const numVal = Number(
      formState.currentEditingValue ??
        selectedNodeParamsValue.double_value ??
        selectedNodeParamsValue.integer_value,
    );
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
            // Use context.setParameter instead of callService
            console.log(
              `Setting parameter ${fullParamName} to ${value} via context.setParameter`,
            );
            context.setParameter(fullParamName, value);
            setFormState({ currentEditingValue: value });
          }}
          style={{ padding: "1rem", flexGrow: 1 }}
        />
        <div>{numVal.toFixed(2)}</div>
      </div>
    );
  }
  if (settings.inputType === "boolean") {
    const boolVal =
      formState.currentEditingValue == null
        ? selectedNodeParamsValue.bool_value
        : Boolean(formState.currentEditingValue);
    return (
      <input
        type="checkbox"
        checked={boolVal}
        onChange={(e) => {
          const value = e.target.checked;
          console.log(
            `Setting parameter ${fullParamName} to ${value} via context.setParameter`,
          );
          // Use context.setParameter instead of callService
          context.setParameter(fullParamName, value);
          setFormState({ currentEditingValue: value });
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (settings.inputType === "text") {
    const stringVal = String(
      formState.currentEditingValue || selectedNodeParamsValue.string_value,
    );
    return (
      <input
        type="text"
        value={stringVal}
        onChange={(e) => {
          const value = e.target.value;
          // Use context.setParameter instead of callService
          context.setParameter(fullParamName, value);
          setFormState({ currentEditingValue: value });
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
