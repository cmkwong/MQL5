void Concat1DULong(ulong &arr[], ulong data) {
   int currentSize = ArraySize(arr);
   ArrayResize(arr, currentSize + 1);
   arr[currentSize] = data;
}