import { ParameterValueDetails } from "parameter_types";
import { stringToBoolean } from "./mappers";

  /**
   * determines if a string[] contains exlusively booleans
   * @param strArr string[] to check
   * @returns true if strArr only contains booleans, false otherwise
   */
export const isBooleanArr = (strArr: string[]) => {
    let bool: boolean = true;
    strArr.forEach(element => {
      console.log(stringToBoolean(element));
      if(stringToBoolean(element) === undefined)
        bool = false;
    });

    return bool;
  }


  /**
   * Returns the string value of a paramter's value to be outputted on the screen
   * @param   param The parameter value that is converted to a string
   * @returns String representation of param
  */
  export const getParameterValue = (param: ParameterValueDetails) => {
    if(param === undefined) { return "undefined"; }
    switch(param.type) {
      case 1:  return param.bool_value.toString();
      case 2:  return param.integer_value.toString();
      case 3:  return param.double_value.toString();
      case 4:  return param.string_value;
      case 5:  return `[${param.byte_array_value.toString()}]`;
      case 6:  return `[${param.bool_array_value.toString()}]`;
      case 7:  return `[${param.integer_array_value.toString()}]`;
      case 8:  return `[${param.double_array_value.toString()}]`;
      case 9:  return `[${param.string_array_value.toString()}]`;
      default: return "error, invalid type...";
    }
  }