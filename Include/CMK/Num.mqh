// encode macgic number
int Encode3_Bytes(int a, int b, int c) {
   // Required：0<=a,b,c<=255
   return ((a & 0xFF) << 16) | ((b & 0xFF) << 8) | (c & 0xFF);
}

// decode magic number
void Decode3_Bytes(int v, int &a, int &b, int &c) {
   a = (v >> 16) & 0xFF;
   b = (v >> 8) & 0xFF;
   c = v & 0xFF;
}