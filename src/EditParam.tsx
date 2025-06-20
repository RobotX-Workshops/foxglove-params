import { PanelExtensionContext, SettingsTreeAction } from "@foxglove/extension";
import { ParameterDetails } from "parameter_types";
import {
  ReactElement,
  useEffect,
  useLayoutEffect,
  useState,
  useCallback,
  useRef,
} from "react";
import { createRoot } from "react-dom/client";

// import { LoadingSpinner } from "./components/spinner";
import {
  NumericSettings,
  PanelSettings,
  Settings,
  buildSettingsTree,
  settingsActionReducer,
} from "./panelSettings";
import { extractNodeNames, extractParametersForNode } from "./utils/mappers";
// The mapParamValue function is no longer needed as context.setParameter handles typing.
// import { mapParamValue } from "./utils/mappers";

type FormState = {
  currentEditingValue: string | number | boolean | null;
};
type PanelState = {
  settings: Partial<Settings> | undefined;
};

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  const [isLoading, setIsLoading] = useState(true);
  const [settings, setSettings] = useState<PanelSettings>(() => {
    // State initialization is unchanged
    const initialState = context.initialState as PanelState;
    const partialSettings = initialState.settings ?? {};
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
    if (partialSettings == undefined) {
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

  const isInitialMount = useRef(true);

  useEffect(() => {
    // Using the direct WebSocket connection from your example
    const websocket = new WebSocket("ws://localhost:8765", [
      "foxglove.websocket.v1",
    ]);

    websocket.onopen = () => {
      console.log("WebSocket connection established");
      setIsLoading(true);
      websocket.send(
        JSON.stringify({
          op: "getParameters",
          parameterNames: [], // Request all parameters
          id: "fetch-all-parameters-on-startup",
        }),
      );
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
        setIsLoading(false);
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

  const [formState, setFormState] = useState<FormState>({
    currentEditingValue: null,
  });

  const settingsActionHandler = useCallback((action: SettingsTreeAction) => {
    console.debug("Handling settings action:", action);
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
      console.log(
        `Selected parameter changed to ${settings.selectedParameterName}, resetting form state`,
      );
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
      console.log(
        `Keeping selected parameter ${settings.selectedParameterName} for node ${settings.selectedNode}`,
      );
      selectedParameterName = settings.selectedParameterName;
    }

    // When the node changes, we must update the available parameters
    // AND reset the selected parameter to maintain a consistent state.
    console.debug(
      `Updating available parameters for node ${settings.selectedNode}`,
      paramsForNode,
    );
    // If the selected parameter is not available for the new node, reset it.
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

  const selectedNodeParamsValue = settings.selectedNodeAvailableParams.find(
    (x) => x.name === settings.selectedParameterName,
  )?.value;

  if (isLoading) {
    return <div style={{ padding: "1rem" }}>Loading params data...</div>;
    // return (
    //   <div style={{ padding: "1rem" }}>
    //     <LoadingSpinner />
    //   </div>
    // );
  }

  if (Object.keys(settings.allData).length === 0) {
    return (
      <div style={{ padding: "1rem" }}>
        <p>
          Could not load parameters. Please ensure the WebSocket server is
          running and providing parameter data.
        </p>
      </div>
    );
  }

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

  const fullParamName = `${settings.selectedNode}.${settings.selectedParameterName}`;

  if (settings.inputType === "number") {
    const numberSettings = settings as NumericSettings;
    console.log(
      `Rendering number input for parameter ${fullParamName} with settings:`,
      numberSettings,
    );
    // eslint-disable-next-line @typescript-eslint/restrict-template-expressions
    console.log(`Current editing value: ${formState.currentEditingValue}`);
    console.log(
      // eslint-disable-next-line @typescript-eslint/restrict-template-expressions
      `Selected node parameter value ${selectedNodeParamsValue} : ${selectedNodeParamsValue} (double) or ${selectedNodeParamsValue} (integer)`,
    );
    const numVal = Number(
      formState.currentEditingValue ?? selectedNodeParamsValue,
    );
    console.log(
      `Rendering number input for parameter ${fullParamName} with value ${numVal}`,
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
      formState.currentEditingValue ?? selectedNodeParamsValue,
    );
    if (typeof numVal !== "number") {
      console.warn(
        `Expected number value for parameter ${fullParamName}, but got: ${numVal}`,
      );
      return <div>Invalid boolean value</div>;
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
    const boolVal = formState.currentEditingValue ?? selectedNodeParamsValue;
    if (typeof boolVal !== "boolean") {
      console.warn(
        // eslint-disable-next-line @typescript-eslint/restrict-template-expressions
        `Expected boolean value for parameter ${fullParamName}, but got: ${boolVal}`,
      );
      return <div>Invalid boolean value</div>;
    }
    return (
      <input
        type="checkbox"
        checked={boolVal}
        onChange={(e) => {
          const value = e.target.checked;
          console.log(
            // eslint-disable-next-line @typescript-eslint/restrict-template-expressions
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
    const stringVal = String(formState.currentEditingValue);
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
