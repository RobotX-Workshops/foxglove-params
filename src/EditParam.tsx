import { PanelExtensionContext, SettingsTreeAction } from "@foxglove/extension";
import { ReactElement, useEffect, useLayoutEffect, useState, useCallback } from "react";
import { NumericSettings, PanelSettings, Settings, buildSettingsTree, settingsActionReducer } from "./panelSettings";
import { createRoot } from "react-dom/client";
import { ParameterDetails, ParameterValueDetails } from "parameter_types";
import { mapParamValue } from "./utils/mappers";

type FormState = {
  currentEditingValue: string | number | boolean | null;
}
type PanelState = {
  settings: Partial<Settings> | undefined;
}

function EditParamPanel({ context }: { context: PanelExtensionContext }): ReactElement {

  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  const [settings, setSettings] = useState<PanelSettings>(() => {
    const initialState = context.initialState as PanelState;
    const partialSettings = initialState.settings ?? {};
    if (partialSettings === undefined) {
      console.log("No initial state found");
      return {
        selectedNode: '',
        availableNodeNames: [],
        selectedParameterName: '',
        selectedNodeAvailableParams: [],
        inputType: 'number',
      };
    }
    if (partialSettings.inputType == 'number' || partialSettings.inputType == 'slider') {
      const numberSettings = partialSettings as NumericSettings;
      return {
        selectedNode: partialSettings.selectedNode ?? '',
        availableNodeNames: partialSettings.availableNodeNames ?? [],
        selectedParameterName: partialSettings.selectedParameterName ?? '',
        selectedNodeAvailableParams: partialSettings.selectedNodeAvailableParams ?? [],
        inputType: partialSettings.inputType,
        min: numberSettings.min ?? -100,
        max: numberSettings.max ?? 100,
        step: numberSettings.step ?? 0.1,
      };
    }
    return {
      selectedNode: partialSettings.selectedNode ?? '',
      availableNodeNames: partialSettings.availableNodeNames ?? [],
      selectedParameterName: partialSettings.selectedParameterName ?? '',
      selectedNodeAvailableParams: partialSettings.selectedNodeAvailableParams ?? [],
      inputType: partialSettings.inputType ?? 'number',
    };
  });

  const [formState, setFormState] = useState<FormState>(() => ({currentEditingValue: null }));

  const settingsActionHandler = useCallback(
    (action: SettingsTreeAction) => {
      console.log("Settings action handler", action);
      
      setSettings((prevConfig) => {
        const newConfig = settingsActionReducer(prevConfig, action);
        console.log("New config", newConfig);
        return newConfig;
      }
      );
    },
    [setSettings],
  );

  // Register the settings tree
  useEffect(() => {
    console.log("Registering settings tree");
    context.updatePanelSettingsEditor({
      actionHandler: settingsActionHandler,
      nodes: buildSettingsTree(settings),
    });
    console.log("Savings settings tree", settings);
    context.saveState({
      settings: settings,
    });
    console.log("Settings saved", settings);
  }, [settings, context, settingsActionHandler]);


  useEffect(() => {
    if (!settings.selectedNode) {
      console.log("No node selected");
      return;
    }
    // Reset editing value when the selected node changes
    console.log(`Selected node changed to '${settings.selectedNode}', resetting editing value`);
    
    /**
     * Retrieves a list of all parameters for the current node and their values
    */
   context.callService?.(settings.selectedNode + "/list_parameters", {})
   .then((_value: unknown) => {
     const paramNameList = (_value as any).result.names as string[];
     
     // Return the next promise to enable proper chaining
     return { paramNameList, promise: context.callService?.(settings.selectedNode + "/get_parameters", { names: paramNameList }) };
    })
    .then((data) => {
      if (!data || !data.promise) return;
      
      const { paramNameList, promise } = data;
      
      return promise.then((_valueResult: unknown) => {
        const paramValList = (_valueResult as any).values as ParameterValueDetails[]
        
        // Create a new array with transformed values instead of mutating the original
        const cleanedParamValList = paramValList.map((paramVal, index) => {
          const cleanedParam = { ...paramVal }; // Create a shallow copy
          
          // Iterate over object keys
          for (const key in cleanedParam) {
            if (Object.prototype.hasOwnProperty.call(cleanedParam, key)) {
              // Check for undefined or null values
              if (cleanedParam[key] === undefined || cleanedParam[key] === null) {
                console.log(`Parameter ${key} is undefined or null at index ${index}`);
                continue; // Skip to next iteration
              }
              
              // Handle BigInt conversion as big ints breal the JSON serialization
              if (typeof cleanedParam[key] === "bigint") {
                cleanedParam[key] = Number(cleanedParam[key]) as any; // Type assertion might be needed
              }
            }
          }
          
          return cleanedParam;
        });
        
        // Create combined parameter objects with names and values
        const tempList: Array<ParameterDetails> = paramNameList.map((name, i) => ({
          name: name,
          value: cleanedParamValList[i]!
        }));
        
        // Only update state if we have parameters
        if (tempList.length > 0) {

          setSettings({ ...settings, selectedNodeAvailableParams: tempList });
        }
        setFormState((prevConfig) => ({ ...prevConfig, currentEditingValue: null }));
        });
      })
      .catch((error) => {
        console.error(`error, failed to retrieve parameters: ${error.message}`);
      });
  }, [settings.selectedNode, context]);


  /**
  * Updates the list of nodes when a new node appears
  */
  const updateNodeList = () => {
    console.log("retrieving nodes...")
    context.callService?.("/rosapi/nodes", {})
      .then((_values: unknown) => {
        const nodeNames = (_values as any).nodes as string[];
        console.log("Received node names", nodeNames);

        if (nodeNames.length === 0) {
          console.log("No nodes found");
          return;
        }

        // Sort both arrays for comparison
        const sortedNewNodes = [...nodeNames].sort();
        const sortedCurrentNodes = [...settings.availableNodeNames].sort();

        // Check if arrays have different lengths or different content
        let nodesChanged = sortedNewNodes.length !== sortedCurrentNodes.length;

        if (!nodesChanged) {
          // Arrays are the same length, check if contents match
          for (let i = 0; i < sortedNewNodes.length; i++) {
            if (sortedNewNodes[i] !== sortedCurrentNodes[i]) {
              nodesChanged = true;
              break;
            }
          }
        }

        if (nodesChanged) {
          console.log("Node names changed, updating config");
          setSettings({ ...settings, availableNodeNames: sortedNewNodes });
        } else {
          console.log("No change in node names");
        }
      })
      .catch((_error: Error) => { console.error(_error.toString()); });
  }

  updateNodeList();
 

  // We use a layout effect to setup render handling for our panel. We also setup some topic subscriptions.
  useLayoutEffect(() => {
    console.log("Setting up render handler");
    // The render handler is run by the broader studio system during playback when your panel
    // needs to render because the fields it is watching have changed. How you handle rendering depends on your framework.
    // You can only setup one render handler - usually early on in setting up your panel.
    //
    // Without a render handler your panel will never receive updates.
    //
    // The render handler could be invoked as often as 60hz during playback if fields are changing often.
    context.onRender = (renderState, done) => {
      // render functions receive a _done_ callback. You MUST call this callback to indicate your panel has finished rendering.
      // Your panel will not receive another render callback until _done_ is called from a prior render. If your panel is not done
      // rendering before the next render call, studio shows a notification to the user that your panel is delayed.
      //
      // Set the done callback into a state variable to trigger a re-render.
      console.log("Render state params", renderState.parameters);
      setRenderDone(() => done);
    };

  }, [context]);

  // invoke the done callback once the render is complete
  useEffect(() => {
    renderDone?.();
  }, [renderDone]);


  if (settings === undefined || settings === null || settings.selectedNodeAvailableParams === undefined || settings.selectedParameterName === undefined)
    return <div>Loading...</div>;

  console.log("Current editing value", formState.currentEditingValue);

  const selectedNodeParamsValue = settings.selectedNodeAvailableParams.filter(x => x.name == settings.selectedParameterName)[0]?.value;
  console.log("Selected node value", selectedNodeParamsValue);

  

  // Check if the selected node has a valu
  if (!selectedNodeParamsValue) {
    return <div>No value found. Setup correctly in panel settings</div>;
  }

  if (settings.inputType === "number") {
    const numberSettings = settings as NumericSettings;

    const numVal = Number(formState.currentEditingValue || selectedNodeParamsValue.double_value || selectedNodeParamsValue.integer_value);
    console.log("numVal", numVal);
    return (
      <div
      style={{ display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "center" } }
      >
        <input
          type="number"
          min={numberSettings.min}
          max={numberSettings.max}
          step={numberSettings.step}
          value={numVal}
          onChange={(e) => {
            const value = e.target.value;
            console.log("e.target.value", value)
            const service_url = settings.selectedNode + "/set_parameters";
            console.log("service_url", service_url)
            const parametersPayload = { parameters: [{ name: settings.selectedParameterName, value: mapParamValue(selectedNodeParamsValue, value) }] as ParameterDetails[] };
            console.log("parameters_payload", parametersPayload)

            context.callService?.(
              service_url,
              parametersPayload
            )
            setFormState((prevConfig) => ({ ...prevConfig, currentEditingValue: value, }));
          }}
          style={{ padding: "1rem" }}
        />
      </div>
    );
  }
  if (settings.inputType === "slider") {
    const numVal = Number(formState.currentEditingValue || selectedNodeParamsValue.double_value || selectedNodeParamsValue.integer_value);
    console.log("numVal", numVal);
    const sliderSettings = settings as NumericSettings;
    return (
      <div
      style={{ display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "center" } }
      >

        <input
          type="range"
          min={sliderSettings.min}
          max={sliderSettings.max}
          step={sliderSettings.step}
          value={numVal}
          onChange={(e) => {
            const value = e.target.value;
            console.log("inputrange", value)
            const service_url = settings.selectedNode + "/set_parameters";
            console.log("service_url", service_url)
            const parametersPayload = { parameters: [{ name: settings.selectedParameterName, value: mapParamValue(selectedNodeParamsValue, value) }] as ParameterDetails[] };
            console.log("parameters_payload", parametersPayload)
            context.callService?.(
              service_url,
              parametersPayload
            )
            setFormState((prevConfig) => ({ ...prevConfig, currentEditingValue: value }));
          }}
          style={{ padding: "1rem" }}
        />
        <div>{numVal}</div>
      </div>
    );
  }
  if (settings.inputType === "boolean") {
    const boolVal = Boolean(formState.currentEditingValue || selectedNodeParamsValue.bool_value);

    return (
      <input
        type="checkbox"
        checked={boolVal}
        onChange={(e) => {
          const value = e.target.value;
          console.log("inputcheckbox val", value, typeof (value))
          const parametersPayload = { parameters: [{ name: settings.selectedParameterName, value: mapParamValue(selectedNodeParamsValue, value) }] as ParameterDetails[] };

          context.callService?.(
            settings.selectedNode + "/set_parameters",
            parametersPayload
          )
          setFormState((prevConfig) => ({ ...prevConfig, currentEditingValue: value }));
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (settings.inputType === "text") {
    const stringVal = String(formState.currentEditingValue || selectedNodeParamsValue.bool_value);
    return (
      <input
        type="text"
        value={stringVal}
        onChange={(e) => {
          const value = e.target.value;
          const parametersPayload = { parameters: [{ name: settings.selectedParameterName, value: mapParamValue(selectedNodeParamsValue, value) }] as ParameterDetails[] };
          context.callService?.(
            settings.selectedNode + "/set_parameters",
            parametersPayload
          )
          setFormState((prevConfig) => ({ ...prevConfig, currentEditingValue: value }));
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

  // Return a function to run when the panel is removed
  return () => {
    root.unmount();
  };
}
