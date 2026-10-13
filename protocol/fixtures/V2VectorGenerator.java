// Synthetic test keys from RFC 7748; never use these keys in production.
import java.security.spec.*;import java.util.*;import java.nio.*;import java.nio.charset.*;import java.security.*;import javax.crypto.*;import javax.crypto.spec.*;
public class V2VectorGenerator {
 static byte[] hex(String s){return HexFormat.of().parseHex(s);} static String hex(byte[] b){return HexFormat.of().formatHex(b);}
 static byte[] cat(byte[]... a){int n=0;for(byte[] b:a)n+=b.length;ByteBuffer r=ByteBuffer.allocate(n);for(byte[] b:a)r.put(b);return r.array();}
 static byte[] mac(byte[] k,byte[] d)throws Exception{Mac m=Mac.getInstance("HmacSHA256");m.init(new SecretKeySpec(k,"HmacSHA256"));return m.doFinal(d);}
 static byte[] derive(byte[] k,byte[] salt,String info,int n)throws Exception{byte[] p=mac(salt.length==0?new byte[32]:salt,k),prev=new byte[0],out=new byte[n];int o=0,i=1;while(o<n){prev=mac(p,cat(prev,info.getBytes(StandardCharsets.UTF_8),new byte[]{(byte)i++}));int c=Math.min(32,n-o);System.arraycopy(prev,0,out,o,c);o+=c;}return out;}
 static byte[] hello(int role,String id,byte b,byte[] pub){byte[] nonce=new byte[32];Arrays.fill(nonce,b);UUID u=UUID.fromString(id);return ByteBuffer.allocate(105).put("Ciallo~".getBytes(StandardCharsets.US_ASCII)).put((byte)2).put((byte)role).putLong(u.getMostSignificantBits()).putLong(u.getLeastSignificantBits()).put(new byte[16]).put(nonce).put(pub).array();}
 public static void main(String[] args)throws Exception{
  byte[] ap=hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
    au=hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
    bu=hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
  KeyFactory kf=KeyFactory.getInstance("XDH"); KeyAgreement ka=KeyAgreement.getInstance("XDH");
  ka.init(kf.generatePrivate(new PKCS8EncodedKeySpec(cat(hex("302e020100300506032b656e04220420"),ap))));
  ka.doPhase(kf.generatePublic(new X509EncodedKeySpec(cat(hex("302a300506032b656e032100"),bu))),true);
  byte[] shared=ka.generateSecret();
  if(!hex(shared).equals("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"))throw new AssertionError("RFC7748");
  byte[] key=new byte[32];Arrays.fill(key,(byte)3);byte[] a=hello(1,"11111111-1111-1111-1111-111111111111",(byte)1,au),b=hello(2,"22222222-2222-2222-2222-222222222222",(byte)2,bu);
  byte[] salt=cat(Arrays.copyOfRange(a,41,73),Arrays.copyOfRange(b,41,73));byte[] transcript=cat("Andcintosh/v2/ble/".getBytes(StandardCharsets.UTF_8),a,b);
  String d=hex(MessageDigest.getInstance("SHA-256").digest(transcript));byte[] root=derive(shared,mac(key,salt),"Andcintosh/v2/session/"+d,32),tx=derive(root,new byte[0],"key/mac/0",32),prefix=derive(root,new byte[0],"nonce/mac",4);
  byte[] record=ByteBuffer.allocate(48).put((byte)2).put(new byte[16]).put(hex("33333333333333333333333333333333")).putLong(1L<<40).putInt(0).put(new byte[]{0,(byte)128,(byte)255}).array();
  byte[] header=ByteBuffer.allocate(12).putInt(record.length+16).putLong(0).array();Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(tx,"AES"),new GCMParameterSpec(128,cat(prefix,new byte[8])));cipher.updateAAD(header);
  String[] names={"sharedSecret","macPrivateKey","key","macHello","androidHello","root","macProof","record","sealed"};byte[][] vals={shared,ap,key,a,b,root,mac(key,cat("Andcintosh/v2/proof/".getBytes(StandardCharsets.UTF_8),new byte[]{1},transcript)),record,cat(header,cipher.doFinal(record))};
  StringBuilder json=new StringBuilder("{");for(int i=0;i<names.length;i++){if(i>0)json.append(',');json.append('"').append(names[i]).append("\":\"").append(hex(vals[i])).append('"');}System.out.println(json.append('}'));
 }
}