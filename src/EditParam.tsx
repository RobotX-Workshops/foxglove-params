import { PanelExtensionContext } from "@foxglove/extension";
import { ReactElement, useEffect } from "react";
import { createRoot } from "react-dom/client";

function EditParamPanel({
  context,
}: {
  context: PanelExtensionContext;
}): ReactElement {
  console.log("Initializing EditParamPanel component.");

  useEffect(() => {
    console.log("EditParamPanel effect is running.");

    // Tell Foxglove we want to receive parameter updates.
    context.watch("parameters");

    // Set up the render handler. This is called by Foxglove when data changes.
    context.onRender = (renderState, done) => {
      console.log("onRender called!"); // This should now appear in the console.
      if (renderState.parameters) {
        console.log("Received parameters:", renderState.parameters);
        renderState.parameters.forEach((value, name) => {
          console.log(`Parameter update: ${name} =`, value);
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
