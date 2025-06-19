import { stringToBoolean } from "./mappers";

/**
 * determines if a string[] contains exlusively booleans
 * @param strArr string[] to check
 * @returns true if strArr only contains booleans, false otherwise
 */
export const isBooleanArr = (strArr: string[]) => {
  let bool = true;
  strArr.forEach((element) => {
    console.log(stringToBoolean(element));
    if (stringToBoolean(element) === undefined) {
      bool = false;
    }
  });

  return bool;
};