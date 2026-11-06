import Foundation

/// Bounded config JSON/JSONC reader. Comments and quotes are handled separately,
/// so URLs and key values containing // are never rewritten as comments.
enum ConfigJSON {
    static func object(_ text: String) -> Any? {
        guard text.utf8.count <= 1_048_576 else { return nil }
        if let data=text.data(using:.utf8),let value=try? JSONSerialization.jsonObject(with:data){return value}
        let chars=Array(text);var result="",index=0
        while index<chars.count {
            let c=chars[index]
            if c=="/",index+1<chars.count,chars[index+1]=="/" {
                index+=2;while index<chars.count && chars[index] != "\n" {index+=1};result+="\n";continue
            }
            if c=="/",index+1<chars.count,chars[index+1]=="*" {
                index+=2;var closed=false
                while index+1<chars.count {if chars[index]=="*",chars[index+1]=="/"{index+=2;closed=true;break};index+=1}
                guard closed else{return nil};result+=" ";continue
            }
            if c=="\"" || c=="'" {
                let quote=c;index+=1;var value="",closed=false
                while index<chars.count {
                    let current=chars[index];index+=1
                    if current==quote {closed=true;break}
                    if current=="\\" {
                        guard index<chars.count else{return nil};let escaped=chars[index];index+=1
                        if quote=="\"" {value+="\\";value.append(escaped)}
                        else {switch escaped {case "n":value+="\n";case "r":value+="\r";case "t":value+="\t";case "'","\\","\"","/":value.append(escaped);default:return nil}}
                    } else {value.append(current)}
                }
                guard closed else{return nil}
                if quote=="\"" {result+="\""+value+"\""}
                else {guard let data=try? JSONSerialization.data(withJSONObject:[value]),let string=String(data:data,encoding:.utf8) else{return nil};result+=String(string.dropFirst().dropLast())}
                continue
            }
            if c.isASCII && (c.isLetter || c=="_" || c=="$") {
                var end=index+1
                while end<chars.count,chars[end].isASCII,(chars[end].isLetter||chars[end].isNumber||chars[end]=="_"||chars[end]=="$"){end+=1}
                var next=end;while next<chars.count,chars[next].isWhitespace{next+=1}
                let word=String(chars[index..<end]),last=result.last(where:{!$0.isWhitespace})
                if next<chars.count,chars[next]==":",last=="{"||last=="," {result+="\""+word+"\""}else{result+=word}
                index=end;continue
            }
            result.append(c);index+=1
        }
        // Remove only structural trailing commas, outside string literals.
        let clean=Array(result);var output="",quoted=false,escape=false;index=0
        while index<clean.count {
            let c=clean[index]
            if quoted {output.append(c);if escape{escape=false}else if c=="\\"{escape=true}else if c=="\""{quoted=false};index+=1;continue}
            if c=="\"" {quoted=true;output.append(c);index+=1;continue}
            if c=="," {var next=index+1;while next<clean.count,clean[next].isWhitespace{next+=1};if next<clean.count,(clean[next]=="}"||clean[next]=="]"){index+=1;continue}}
            output.append(c);index+=1
        }
        return output.data(using:.utf8).flatMap{try? JSONSerialization.jsonObject(with:$0)}
    }
}
