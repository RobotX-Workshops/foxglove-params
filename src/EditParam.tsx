import { PanelExtensionContext, SettingsTreeAction } from "@foxglove/extension";
import { ReactElement, useEffect, useLayoutEffect, useState, useCallback } from "react";
import { Config, buildSettingsTree, settingsActionReducer } from "./panelSettings";
import { createRoot } from "react-dom/client";


function EditParamPanel({ context }: { context: PanelExtensionContext }): ReactElement {

  context.watch('parameters');

  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  const [config, setConfig] = useState<Config>(() => {
    const partialConfig = context.initialState as Partial<Config>;
    partialConfig.selectedNode = partialConfig.selectedNode ?? "";
    partialConfig.availableNodeNames = partialConfig.availableNodeNames ?? [];
    partialConfig.selectedParameter = partialConfig.selectedParameter ?? "";
    partialConfig.selectedNodeAvailableParams = partialConfig.selectedNodeAvailableParams ?? [];
    partialConfig.inputType = partialConfig.inputType ?? "number";
    return partialConfig as Config;
  });

  const settingsActionHandler = useCallback(
    (action: SettingsTreeAction) => {
      console.log("Settings action handler", action);
      setConfig((prevConfig) => settingsActionReducer(prevConfig, action));
    },
    [setConfig],
  );
  // Register the settings tree
  useEffect(() => {
    console.log("Registering settings tree");
    context.updatePanelSettingsEditor({
      actionHandler: settingsActionHandler,
      nodes: buildSettingsTree(config),
    });
  }, [config, context, settingsActionHandler]);

  const updateNodeList = () => {
    console.log("retreiving nodes...")
    context.callService?.("/rosapi/nodes", {})
    .then((_values: unknown) =>{
      setConfig({...config, availableNodeNames: ((_values as any).nodes as string[]).sort()});
      console.log("nodes retreived");
    })
    .catch((_error: Error) => {  console.error(_error.toString()); });
  }

  updateNodeList();

  // We use a layout effect to setup render handling for our panel. We also setup some topic subscriptions.
  useLayoutEffect(() => {
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
      setRenderDone(() => done);
      
      console.log("Render state params", renderState.parameters);

    };

  }, [context]);

  // invoke the done callback once the render is complete
  useEffect(() => {
    renderDone?.();
  }, [renderDone]);

  if (config === undefined || config === null)
    return <div>Loading...</div>;

  if (config.inputType === "number") {
    return (
      <input
        type="number"
        value={config.selectedNodeAvailableParams[0]}
        onChange={(e) => {
          context.setParameter(config.selectedParameter, e.target.value);
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (config.inputType === "slider") {
    return (
      <input
        type="range"
        value={config.selectedNodeAvailableParams[0]}
        onChange={(e) => {
          context.setParameter(config.selectedParameter, e.target.value);
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (config.inputType === "boolean") {
    return (
      <input
        type="checkbox"
        checked={config.selectedNodeAvailableParams[0] === "true"}
        onChange={(e) => {
          context.setParameter(config.selectedParameter, e.target.checked.toString());
        }}
        style={{ padding: "1rem" }}
      />
    );
  }
  if (config.inputType === "select") {
    return (
      <select
        value={config.selectedNodeAvailableParams[0]}
        onChange={(e) => {
          context.setParameter(config.selectedParameter, e.target.value);
        }}
        style={{ padding: "1rem" }}
      >
        {config.selectedNodeAvailableParams.map((param) => (
          <option key={param} value={param}>
            {param}
          </option>
        ))}
      </select>
    );
  }
  if (config.inputType === "text") {
    return (
      <input
        type="text"
        value={config.selectedNodeAvailableParams[0]}
        onChange={(e) => {
          context.setParameter(config.selectedParameter, e.target.value);
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
