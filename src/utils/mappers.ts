import { ParameterDetails, ParameterValueDetails } from "../types";

/**
 * Parses the flat parameter map from Foxglove's renderState into a structured
 * object grouped by node name.
 * @param parameters The Map of parameters from `renderState.parameters`.
 * @returns An object where keys are node names and values are arrays of parameter details.
 */
export function parseParameters(
  parameters: ReadonlyMap<string, unknown>,
): Map<string, Array<ParameterDetails>> {
  const params: Map<string, Array<ParameterDetails>> = new Map<
    string,
    Array<ParameterDetails>
  >();
  // Assuming renderState.parameters is a Map<string, any>
  parameters.forEach((value, name) => {
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
  return params;
}
