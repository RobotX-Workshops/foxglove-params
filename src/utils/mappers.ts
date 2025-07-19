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
  parameters.forEach((value, name) => {
    const parts = name.split(".");

    // The first part is the node name.
    const node_name = parts[0];
    if (!node_name) {
      console.warn(
        `Node name is empty in parameter "${name}". Skipping this parameter.`,
      );
      return;
    }

    // Check if there are enough parts for a parameter name.
    if (parts.length < 2) {
      console.warn(
        `Parameter name is missing in parameter "${name}". Skipping this parameter.`,
      );
      return;
    }

    // All parts after the first are joined to form the parameter name.
    const param_name = parts.slice(1).join(".");

    // Initialize the array for this node if it doesn't exist.
    if (!params.has(node_name)) {
      params.set(node_name, []);
    }

    // Add the parameter details to the node's array.
    // The non-null assertion (!) is safe because we ensure the array exists.
    params.get(node_name)!.push({
      name: param_name,
      value: value as ParameterValueDetails, // Cast to the expected type
    });
  });

  return params;
}
