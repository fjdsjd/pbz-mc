import com.google.gson.Gson;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.FireBlock;

/** Developer-only registry observations. No world/server is started. */
public final class ExportFire {
    public static void main(String[] args) throws Exception {
        SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
        var ignite=FireBlock.class.getDeclaredField("igniteOdds"); ignite.setAccessible(true);
        var burn=FireBlock.class.getDeclaredField("burnOdds"); burn.setAccessible(true);
        var a=(Map<?,?>)ignite.get(Blocks.FIRE); var b=(Map<?,?>)burn.get(Blocks.FIRE);
        var result=new TreeMap<String,Object>();
        for(var block:BuiltInRegistries.BLOCK) {
            int i=a.containsKey(block)?((Number)a.get(block)).intValue():0;
            int j=b.containsKey(block)?((Number)b.get(block)).intValue():0;
            boolean lava=block.defaultBlockState().ignitedByLava();
            if(i>0 || j>0 || lava) result.put(BuiltInRegistries.BLOCK.getKey(block).getPath(),List.of(i,j,lava));
        }
        Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    }
}
